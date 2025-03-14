#import "WebRTCFrameConverter.h"
#import "logger.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

@implementation WebRTCFrameConverter {
    RTCVideoFrame *_lastFrame;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _processingQueue;
    BOOL _isReceivingFrames;
    int _frameCount;
    NSTimeInterval _lastFrameTime;
    CFTimeInterval _maxFrameRate;
    CIContext *_ciContext;
    CGSize _lastFrameSize;
    NSTimeInterval _lastPerformanceLogTime;
    float _frameProcessingTimes[10]; // Média móvel para monitorar desempenho
    int _frameTimeIndex;
    BOOL _didLogFirstFrameDetails;
    
    // Variáveis para adaptação automática
    CMVideoDimensions _targetResolution;
    CMTime _targetFrameDuration;
    BOOL _adaptToTargetResolution;
    BOOL _adaptToTargetFrameRate;
    dispatch_semaphore_t _frameProcessingSemaphore;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Criar contexto de processamento de imagem otimizado
        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),  // Usar GPU quando disponível
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        };
        _ciContext = [CIContext contextWithOptions:options];
        
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing",
                                               DISPATCH_QUEUE_CONCURRENT); // Usar fila concorrente para melhor desempenho
        
        _isReceivingFrames = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _maxFrameRate = 1.0 / 60.0; // Suporte a até 60 fps
        _lastFrameSize = CGSizeZero;
        _lastPerformanceLogTime = 0;
        _didLogFirstFrameDetails = NO;
        
        // Inicialização de adaptação automática
        _targetResolution.width = 0;  // Inicializa com zeros - corrigido
        _targetResolution.height = 0; // Inicializa com zeros - corrigido
        _targetFrameDuration = CMTimeMake(1, 30); // Default 30 fps
        _adaptToTargetResolution = NO;
        _adaptToTargetFrameRate = NO;
        _frameProcessingSemaphore = dispatch_semaphore_create(1);
        
        // Inicializar array de tempos de processamento
        for (int i = 0; i < 10; i++) {
            _frameProcessingTimes[i] = 0.0f;
        }
        _frameTimeIndex = 0;
        
        writeLog(@"[WebRTCFrameConverter] Inicializado com configurações otimizadas para alta resolução e adaptação automática");
    }
    return self;
}

- (void)dealloc {
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
    // CIContext é tratado pelo ARC
}

- (BOOL)isReceivingFrames {
    return _isReceivingFrames;
}

#pragma mark - Configuração de adaptação

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    _targetResolution = resolution;
    _adaptToTargetResolution = (resolution.width > 0 && resolution.height > 0);
    
    writeLog(@"[WebRTCFrameConverter] Resolução alvo definida para %dx%d (adaptação %@)",
             resolution.width, resolution.height,
             _adaptToTargetResolution ? @"ativada" : @"desativada");
}

- (void)setTargetFrameRate:(float)frameRate {
    if (frameRate <= 0) {
        _adaptToTargetFrameRate = NO;
        return;
    }
    
    _targetFrameDuration = CMTimeMake(1, (int32_t)frameRate);
    _adaptToTargetFrameRate = YES;
    
    writeLog(@"[WebRTCFrameConverter] Taxa de quadros alvo definida para %.1f fps (adaptação %@)",
             frameRate, _adaptToTargetFrameRate ? @"ativada" : @"desativada");
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
    writeLog(@"[WebRTCFrameConverter] setSize chamado: %@", NSStringFromCGSize(size));
    
    // Verificar se o tamanho mudou significativamente
    if (_lastFrameSize.width != size.width || _lastFrameSize.height != size.height) {
        writeLog(@"[WebRTCFrameConverter] Tamanho do frame mudou: %@ -> %@",
                 NSStringFromCGSize(_lastFrameSize),
                 NSStringFromCGSize(size));
        
        _lastFrameSize = size;
    }
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (!frame || frame.width == 0 || frame.height == 0) {
        return;
    }
    
    NSTimeInterval startTime = CACurrentMediaTime();
    
    // Adaptação de taxa de quadros (se habilitada)
    if (_adaptToTargetFrameRate) {
        NSTimeInterval currentTime = startTime;
        NSTimeInterval elapsed = currentTime - _lastFrameTime;
        NSTimeInterval targetElapsed = CMTimeGetSeconds(_targetFrameDuration);
        
        if (elapsed < targetElapsed && _frameCount > 1) {
            // Pular este frame para manter a taxa desejada
            return;
        }
    } else {
        // Caso contrário, usar a limitação padrão para dispositivos com recursos limitados
        NSTimeInterval currentTime = startTime;
        NSTimeInterval elapsed = currentTime - _lastFrameTime;
        
        if (elapsed < _maxFrameRate && _frameCount > 1) {
            // Pular este frame para manter a taxa desejada
            return;
        }
    }
    
    _lastFrameTime = startTime;
    
    // Thread safety
    @synchronized(self) {
        _frameCount++;
        _isReceivingFrames = YES;
        _lastFrame = frame;
    }
    
    // Log detalhado apenas para o primeiro frame e depois a cada 300 frames
    if (!_didLogFirstFrameDetails || _frameCount % 300 == 0) {
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        
        writeLog(@"[WebRTCFrameConverter] Frame #%d: %dx%d, rotação: %ld, tipo de buffer: %@",
                _frameCount,
                (int)frame.width,
                (int)frame.height,
                (long)frame.rotation,
                NSStringFromClass([buffer class]));
        
        // Verificar formato específico para RTCCVPixelBuffer
        if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
            CVPixelBufferRef cvBuffer = pixelBuffer.pixelBuffer;
            
            if (cvBuffer) {
                OSType pixelFormatType = CVPixelBufferGetPixelFormatType(cvBuffer);
                char formatChars[5] = {
                    (char)((pixelFormatType >> 24) & 0xFF),
                    (char)((pixelFormatType >> 16) & 0xFF),
                    (char)((pixelFormatType >> 8) & 0xFF),
                    (char)(pixelFormatType & 0xFF),
                    0
                };
                
                writeLog(@"[WebRTCFrameConverter] Formato de pixel: %s (0x%08X)",
                        formatChars, (unsigned int)pixelFormatType);
                
                size_t width = CVPixelBufferGetWidth(cvBuffer);
                size_t height = CVPixelBufferGetHeight(cvBuffer);
                size_t bytesPerRow = CVPixelBufferGetBytesPerRow(cvBuffer);
                
                writeLog(@"[WebRTCFrameConverter] Tamanho do buffer: %zux%zu, bytesPerRow: %zu",
                        width, height, bytesPerRow);
            }
        }
        
        _didLogFirstFrameDetails = YES;
    }
    
    // Processamento no thread principal ou em background
    if (!self.frameCallback) {
        return;
    }
    
    // Verificar se já temos um processamento em andamento
    if (dispatch_semaphore_wait(_frameProcessingSemaphore, DISPATCH_TIME_NOW) != 0) {
        // Já existe um frame sendo processado, pular este
        return;
    }
    
    // Processamento em thread separada com controle de desempenho
    dispatch_async(_processingQueue, ^{
        @try {
            NSTimeInterval conversionStartTime = CACurrentMediaTime();
            
            // Determinar se precisa adaptar a resolução
            UIImage *image;
            if (self->_adaptToTargetResolution &&
                self->_targetResolution.width > 0 &&
                self->_targetResolution.height > 0) {
                
                // Converter e adaptar para a resolução alvo
                image = [self adaptedImageFromVideoFrame:frame];
            } else {
                // Conversão normal
                image = [self imageFromVideoFrame:frame];
            }
            
            NSTimeInterval conversionTime = CACurrentMediaTime() - conversionStartTime;
            
            // Armazenar tempo de processamento para média móvel
            self->_frameProcessingTimes[self->_frameTimeIndex] = conversionTime;
            self->_frameTimeIndex = (self->_frameTimeIndex + 1) % 10;
            
            // Calcular tempo médio a cada 10 segundos
            if (CACurrentMediaTime() - self->_lastPerformanceLogTime > 10.0) {
                float averageTime = 0;
                for (int i = 0; i < 10; i++) {
                    averageTime += self->_frameProcessingTimes[i];
                }
                averageTime /= 10.0;
                
                writeLog(@"[WebRTCFrameConverter] Tempo médio de processamento: %.2f ms, FPS estimado: %.1f",
                        averageTime * 1000.0,
                        averageTime > 0 ? 1.0/averageTime : 0);
                
                self->_lastPerformanceLogTime = CACurrentMediaTime();
            }
            
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.frameCallback(image);
                    
                    // Liberar o semáforo após o callback ser processado
                    dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                });
            } else {
                writeLog(@"[WebRTCFrameConverter] Falha ao converter frame para UIImage");
                dispatch_semaphore_signal(self->_frameProcessingSemaphore);
            }
        } @catch (NSException *exception) {
            writeLog(@"[WebRTCFrameConverter] Exceção ao processar frame: %@", exception);
            dispatch_semaphore_signal(self->_frameProcessingSemaphore);
        }
    });
}

- (void)setRenderFrame:(RTCVideoFrame *)frame {
    [self renderFrame:frame];
}

#pragma mark - Processamento de Frame

- (UIImage *)imageFromVideoFrame:(RTCVideoFrame *)frame {
    @try {
        if (!frame) {
            return nil;
        }
        
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        
        // Método otimizado para RTCCVPixelBuffer
        if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
            CVPixelBufferRef cvPixelBuffer = pixelBuffer.pixelBuffer;
            
            if (!cvPixelBuffer) {
                writeLog(@"[WebRTCFrameConverter] CVPixelBuffer é NULL");
                return nil;
            }
            
            // Usar um tratamento mais seguro com autoreleasepool
            @autoreleasepool {
                // Bloquear o buffer para acesso
                CVReturn lockResult = CVPixelBufferLockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                if (lockResult != kCVReturnSuccess) {
                    writeLog(@"[WebRTCFrameConverter] Falha ao bloquear CVPixelBuffer: %d", (int)lockResult);
                    return nil;
                }
                
                UIImage *image = nil;
                
                // Usar abordagem mais eficiente com CIImage
                CIImage *ciImage = [CIImage imageWithCVPixelBuffer:cvPixelBuffer];
                
                // Aplicar rotação se necessário
                if (frame.rotation != RTCVideoRotation_0) {
                    CGAffineTransform transform = CGAffineTransformIdentity;
                    
                    switch (frame.rotation) {
                        case RTCVideoRotation_90:
                            transform = CGAffineTransformMakeRotation(M_PI_2);
                            break;
                        case RTCVideoRotation_180:
                            transform = CGAffineTransformMakeRotation(M_PI);
                            break;
                        case RTCVideoRotation_270:
                            transform = CGAffineTransformMakeRotation(-M_PI_2);
                            break;
                        default:
                            break;
                    }
                    
                    ciImage = [ciImage imageByApplyingTransform:transform];
                }
                
                // Usar o contexto otimizado para criar CGImage
                CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
                
                CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                
                if (!cgImage) {
                    writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage");
                    return nil;
                }
                
                image = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                
                if (!image) {
                    writeLog(@"[WebRTCFrameConverter] Falha ao criar UIImage a partir de CGImage");
                    return nil;
                }
                
                return image;
            }
        }
        // Método alternativo para I420Buffer
        // Correção para a parte que contém o erro da variável strideV.
        // Esta não é a implementação completa, apenas o trecho que precisa ser corrigido.

        else if ([buffer isKindOfClass:[RTCI420Buffer class]]) {
            writeLog(@"[WebRTCFrameConverter] Processando buffer I420");
            
            RTCI420Buffer *i420Buffer = (RTCI420Buffer *)buffer;
            
            // Obter os planos Y, U, V do buffer I420
            const uint8_t *dataY = i420Buffer.dataY;
            const uint8_t *dataU = i420Buffer.dataU;
            const uint8_t *dataV = i420Buffer.dataV;
            
            int width = i420Buffer.width;
            int height = i420Buffer.height;
            int strideY = i420Buffer.strideY;
            int strideU = i420Buffer.strideU;
            // Removendo a declaração não utilizada de strideV
            
            // Criar um CVPixelBuffer para converter I420 para BGRA
            CVPixelBufferRef pixelBuffer = NULL;
            CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                               width,
                                               height,
                                               kCVPixelFormatType_32BGRA,
                                               NULL,
                                               &pixelBuffer);
            
            if (result != kCVReturnSuccess || pixelBuffer == NULL) {
                writeLog(@"[WebRTCFrameConverter] Falha ao criar CVPixelBuffer para conversão I420");
                return nil;
            }
            
            // Bloquear o buffer para escrita
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            
            // Obter ponteiro para dados BGRA
            uint8_t *bgraData = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
            
            // Converter I420 para BGRA
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int yIndex = y * strideY + x;
                    int uvIndex = (y / 2) * strideU + (x / 2);
                    
                    uint8_t yValue = dataY[yIndex];
                    uint8_t uValue = dataU[uvIndex];
                    uint8_t vValue = dataV[uvIndex];  // Usando diretamente dataV com o mesmo índice que dataU
                    
                    // Conversão YUV para RGB
                    int c = yValue - 16;
                    int d = uValue - 128;
                    int e = vValue - 128;
                    
                    uint8_t r = (uint8_t)MAX(0, MIN(255, (298 * c + 409 * e + 128) >> 8));
                    uint8_t g = (uint8_t)MAX(0, MIN(255, (298 * c - 100 * d - 208 * e + 128) >> 8));
                    uint8_t b = (uint8_t)MAX(0, MIN(255, (298 * c + 516 * d + 128) >> 8));
                    
                    // BGRA (little-endian)
                    int bgraIndex = y * bytesPerRow + x * 4;
                    bgraData[bgraIndex + 0] = b;  // B
                    bgraData[bgraIndex + 1] = g;  // G
                    bgraData[bgraIndex + 2] = r;  // R
                    bgraData[bgraIndex + 3] = 255;  // A (opaco)
                }
            }
            
            // Criar CIImage a partir do buffer BGRA
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
            
            // Aplicar rotação se necessário
            if (frame.rotation != RTCVideoRotation_0) {
                CGAffineTransform transform = CGAffineTransformIdentity;
                
                switch (frame.rotation) {
                    case RTCVideoRotation_90:
                        transform = CGAffineTransformMakeRotation(M_PI_2);
                        break;
                    case RTCVideoRotation_180:
                        transform = CGAffineTransformMakeRotation(M_PI);
                        break;
                    case RTCVideoRotation_270:
                        transform = CGAffineTransformMakeRotation(-M_PI_2);
                        break;
                    default:
                        break;
                }
                
                ciImage = [ciImage imageByApplyingTransform:transform];
            }
            
            // Usar o contexto otimizado para criar CGImage
            CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
            
            // Liberar recursos
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            
            if (!cgImage) {
                writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage a partir de buffer I420");
                return nil;
            }
            
            UIImage *image = [UIImage imageWithCGImage:cgImage];
            CGImageRelease(cgImage);
            
            return image;
        }
        else {
            writeLog(@"[WebRTCFrameConverter] Tipo de buffer não suportado: %@", NSStringFromClass([buffer class]));
        }
        
        return nil;
    } @catch (NSException *e) {
        writeLog(@"[WebRTCFrameConverter] Exceção ao converter frame para UIImage: %@", e);
        return nil;
    }
}

#pragma mark - Adaptação para resolução alvo

- (UIImage *)adaptedImageFromVideoFrame:(RTCVideoFrame *)frame {
    // Primeiro, converter o frame para UIImage
    UIImage *originalImage = [self imageFromVideoFrame:frame];
    if (!originalImage) return nil;
    
    // Se a imagem já está na resolução alvo, retorne-a diretamente
    if ((int)originalImage.size.width == _targetResolution.width &&
        (int)originalImage.size.height == _targetResolution.height) {
        return originalImage;
    }
    
    // Calcular proporções para determinar o tipo de adaptação necessária
    float originalAspect = originalImage.size.width / originalImage.size.height;
    float targetAspect = (float)_targetResolution.width / (float)_targetResolution.height;
    
    // Usar um autoreleasepool para controle de memória
    @autoreleasepool {
        CGRect drawRect;
        CGSize finalSize = CGSizeMake(_targetResolution.width, _targetResolution.height);
        
        // Determinar se precisa de cropping ou letterboxing
        if (fabs(originalAspect - targetAspect) < 0.01) {
            // Proporções são quase idênticas, apenas redimensionar
            drawRect = CGRectMake(0, 0, finalSize.width, finalSize.height);
        }
        else if (originalAspect > targetAspect) {
            // Imagem original é mais larga, fazer cropping nos lados
            float scaledHeight = finalSize.height;
            float scaledWidth = scaledHeight * originalAspect;
            float xOffset = (scaledWidth - finalSize.width) / 2.0f;
            
            drawRect = CGRectMake(-xOffset, 0, scaledWidth, scaledHeight);
        }
        else {
            // Imagem original é mais alta, fazer cropping no topo/base
            float scaledWidth = finalSize.width;
            float scaledHeight = scaledWidth / originalAspect;
            float yOffset = (scaledHeight - finalSize.height) / 2.0f;
            
            drawRect = CGRectMake(0, -yOffset, scaledWidth, scaledHeight);
        }
        
        // Iniciar contexto de desenho com a resolução alvo
        UIGraphicsBeginImageContextWithOptions(finalSize, YES, 1.0);
        
        // Preencher fundo preto (para letterboxing)
        [[UIColor blackColor] setFill];
        UIRectFill(CGRectMake(0, 0, finalSize.width, finalSize.height));
        
        // Desenhar a imagem adaptada
        [originalImage drawInRect:drawRect];
        
        // Obter a imagem final
        UIImage *adaptedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (!adaptedImage) {
            writeLog(@"[WebRTCFrameConverter] Falha ao adaptar imagem para resolução alvo %dx%d",
                    _targetResolution.width, _targetResolution.height);
            return originalImage; // Fallback para a imagem original
        }
        
        // Log detalhado apenas ocasionalmente para evitar spam
        if (_frameCount == 1 || _frameCount % 300 == 0) {
            writeLog(@"[WebRTCFrameConverter] Imagem adaptada de %dx%d para %dx%d",
                    (int)originalImage.size.width, (int)originalImage.size.height,
                    (int)adaptedImage.size.width, (int)adaptedImage.size.height);
        }
        
        return adaptedImage;
    }
}

#pragma mark - Conversão para CMSampleBuffer

- (CMSampleBufferRef)getLatestSampleBuffer {
    @try {
        // Se não tivermos um frame, retornar nulo
        if (!_lastFrame) {
            return NULL;
        }
        
        CMSampleBufferRef sampleBuffer = NULL;
        
        // Determinar se precisa adaptar para a resolução alvo
        if (_adaptToTargetResolution && _targetResolution.width > 0 && _targetResolution.height > 0) {
            sampleBuffer = [self getAdaptedSampleBuffer];
        } else {
            // Processo padrão para conversão sem adaptação
            sampleBuffer = [self getOriginalSampleBuffer];
        }
        
        return sampleBuffer;
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCFrameConverter] Exceção em getLatestSampleBuffer: %@", exception);
        return NULL;
    }
}

- (CMSampleBufferRef)getOriginalSampleBuffer {
    if (!_lastFrame) return NULL;
    
    id<RTCVideoFrameBuffer> buffer = _lastFrame.buffer;
    
    // Verificar se temos um CVPixelBuffer
    if (![buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        writeLog(@"[WebRTCFrameConverter] getOriginalSampleBuffer: Buffer não é CVPixelBuffer");
        return NULL;
    }
    
    RTCCVPixelBuffer *rtcPixelBuffer = (RTCCVPixelBuffer *)buffer;
    CVPixelBufferRef pixelBuffer = rtcPixelBuffer.pixelBuffer;
    
    if (!pixelBuffer) {
        writeLog(@"[WebRTCFrameConverter] getOriginalSampleBuffer: pixelBuffer é NULL");
        return NULL;
    }
    
    // Criar um CMVideoFormatDescription a partir do CVPixelBuffer
    CMVideoFormatDescriptionRef formatDescription;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    
    if (status != 0) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMVideoFormatDescription: %d", (int)status);
        return NULL;
    }
    
    // Timestamp para o sample buffer
    CMTimeScale timeScale = 1000000000; // Nanosegundos
    CMTime timestamp = CMTimeMake((int64_t)(CACurrentMediaTime() * timeScale), timeScale);
    
    // Duração do frame (assumindo 30fps ou usando a taxa configurada)
    CMTime duration;
    if (_adaptToTargetFrameRate) {
        duration = _targetFrameDuration;
    } else {
        duration = CMTimeMake(timeScale / 30, timeScale);
    }
    
    // Criar um CMSampleTimingInfo com o timestamp
    CMSampleTimingInfo timingInfo;
    timingInfo.duration = duration;
    timingInfo.presentationTimeStamp = timestamp;
    timingInfo.decodeTimeStamp = kCMTimeInvalid;
    
    // Criar o CMSampleBuffer
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        true, // dataReady
        NULL, // allocator
        NULL, // dataCallback
        formatDescription,
        &timingInfo,
        &sampleBuffer
    );
    
    // Liberar a descrição do formato
    CFRelease(formatDescription);
    
    if (status != 0) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMSampleBuffer: %d", (int)status);
        return NULL;
    }
    
    return sampleBuffer;
}

- (CMSampleBufferRef)getAdaptedSampleBuffer {
    if (!_lastFrame) return NULL;
    
    // Criar um pixel buffer com as dimensões alvo
    CVPixelBufferRef adaptedPixelBuffer = NULL;
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferWidthKey: @(_targetResolution.width),
        (NSString *)kCVPixelBufferHeightKey: @(_targetResolution.height),
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    
    CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        _targetResolution.width,
        _targetResolution.height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)pixelBufferAttributes,
        &adaptedPixelBuffer
    );
    
    if (result != kCVReturnSuccess || adaptedPixelBuffer == NULL) {
        writeLog(@"[WebRTCFrameConverter] Falha ao criar CVPixelBuffer adaptado");
        return NULL;
    }
    
    // Obter a imagem original e adaptar para a resolução alvo
    UIImage *originalImage = [self imageFromVideoFrame:_lastFrame];
    if (!originalImage) {
        CVPixelBufferRelease(adaptedPixelBuffer);
        return NULL;
    }
    
    // Calcular proporções para determinar o tipo de adaptação necessária
    float originalAspect = originalImage.size.width / originalImage.size.height;
    float targetAspect = (float)_targetResolution.width / (float)_targetResolution.height;
    
    // Bloquear buffer para escrita
    CVPixelBufferLockBaseAddress(adaptedPixelBuffer, 0);
    
    // Configurar contexto de desenho para o pixel buffer
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(adaptedPixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(adaptedPixelBuffer);
    
    CGContextRef context = CGBitmapContextCreate(
        baseAddress,
        _targetResolution.width,
        _targetResolution.height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    
    if (!context) {
        writeLog(@"[WebRTCFrameConverter] Falha ao criar contexto de bitmap");
        CVPixelBufferUnlockBaseAddress(adaptedPixelBuffer, 0);
        CVPixelBufferRelease(adaptedPixelBuffer);
        CGColorSpaceRelease(colorSpace);
        return NULL;
    }
    
    // Preencher com fundo preto
    CGContextSetFillColorWithColor(context, [UIColor blackColor].CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, _targetResolution.width, _targetResolution.height));
    
    // Determinar o retângulo de desenho para manter a proporção correta
    CGRect drawRect;
    
    if (fabs(originalAspect - targetAspect) < 0.01) {
        // Proporções são quase idênticas, apenas redimensionar
        drawRect = CGRectMake(0, 0, _targetResolution.width, _targetResolution.height);
    }
    else if (originalAspect > targetAspect) {
        // Imagem original é mais larga, crop nos lados
        float scaledHeight = _targetResolution.height;
        float scaledWidth = scaledHeight * originalAspect;
        float xOffset = (scaledWidth - _targetResolution.width) / 2.0f;
        
        drawRect = CGRectMake(-xOffset, 0, scaledWidth, scaledHeight);
    }
    else {
        // Imagem original é mais alta, crop no topo/base
        float scaledWidth = _targetResolution.width;
        float scaledHeight = scaledWidth / originalAspect;
        float yOffset = (scaledHeight - _targetResolution.height) / 2.0f;
        
        drawRect = CGRectMake(0, -yOffset, scaledWidth, scaledHeight);
    }
    
    // Desenhar a imagem adaptada
    CGContextDrawImage(context, drawRect, originalImage.CGImage);
    
    // Liberar recursos do contexto
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    // Desbloquear o buffer
    CVPixelBufferUnlockBaseAddress(adaptedPixelBuffer, 0);
    
    // Criar uma descrição de formato para o buffer adaptado
    CMVideoFormatDescriptionRef formatDescription;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        adaptedPixelBuffer,
        &formatDescription
    );
    
    if (status != 0) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar descrição de formato para buffer adaptado: %d", (int)status);
        CVPixelBufferRelease(adaptedPixelBuffer);
        return NULL;
    }
    
    // Timestamp para o sample buffer
    CMTimeScale timeScale = 1000000000; // Nanosegundos
    CMTime timestamp = CMTimeMake((int64_t)(CACurrentMediaTime() * timeScale), timeScale);
    
    // Duração do frame (usando a taxa alvo configurada ou default)
    CMTime duration;
    if (_adaptToTargetFrameRate) {
        duration = _targetFrameDuration;
    } else {
        duration = CMTimeMake(timeScale / 30, timeScale); // Default 30fps
    }
    
    // Criar um CMSampleTimingInfo com o timestamp
    CMSampleTimingInfo timingInfo = {
        .duration = duration,
        .presentationTimeStamp = timestamp,
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    // Criar o CMSampleBuffer
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        adaptedPixelBuffer,
        true, // dataReady
        NULL, // allocator
        NULL, // dataCallback
        formatDescription,
        &timingInfo,
        &sampleBuffer
    );
    
    // Liberar recursos
    CFRelease(formatDescription);
    CVPixelBufferRelease(adaptedPixelBuffer);
    
    if (status != 0) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMSampleBuffer adaptado: %d", (int)status);
        return NULL;
    }
    
    if (_frameCount == 1 || _frameCount % 300 == 0) {
        writeLog(@"[WebRTCFrameConverter] CMSampleBuffer adaptado criado com sucesso: %dx%d",
                _targetResolution.width, _targetResolution.height);
    }
    
    return sampleBuffer;
}

#pragma mark - Métodos de Interface Pública

- (UIImage *)getLastFrameAsImage {
    @synchronized(self) {
        if (!_lastFrame) {
            return nil;
        }
        
        if (_adaptToTargetResolution && _targetResolution.width > 0 && _targetResolution.height > 0) {
            return [self adaptedImageFromVideoFrame:_lastFrame];
        } else {
            return [self imageFromVideoFrame:_lastFrame];
        }
    }
}

- (NSDictionary *)getFrameProcessingStats {
    float averageTime = 0;
    for (int i = 0; i < 10; i++) {
        averageTime += _frameProcessingTimes[i];
    }
    averageTime /= 10.0;
    float fps = averageTime > 0 ? 1.0/averageTime : 0;
    
    return @{
        @"averageProcessingTimeMs": @(averageTime * 1000.0),
        @"estimatedFps": @(fps),
        @"frameCount": @(_frameCount),
        @"isReceivingFrames": @(_isReceivingFrames),
        @"adaptToTargetResolution": @(_adaptToTargetResolution),
        @"adaptToTargetFrameRate": @(_adaptToTargetFrameRate),
        @"targetResolution": @{
            @"width": @(_targetResolution.width),
            @"height": @(_targetResolution.height)
        },
        @"targetFrameRate": @(CMTimeGetSeconds(_targetFrameDuration) > 0 ?
                            1.0 / CMTimeGetSeconds(_targetFrameDuration) : 0)
    };
}

@end
