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
    
    // Cache de imagem para otimização de performance
    UIImage *_cachedImage;
    uint64_t _lastFrameHash;
}

@synthesize frameCount = _frameCount;

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
                                               DISPATCH_QUEUE_CONCURRENT);
        
        _isReceivingFrames = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _maxFrameRate = 1.0 / 60.0; // Suporte a até 60 fps
        _lastFrameSize = CGSizeZero;
        _lastPerformanceLogTime = 0;
        _didLogFirstFrameDetails = NO;
        _lastFrameHash = 0;
        
        // Inicialização de adaptação automática
        _targetResolution.width = 0;
        _targetResolution.height = 0;
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
    _cachedImage = nil;
}

- (BOOL)isReceivingFrames {
    return _isReceivingFrames;
}

- (void)reset {
    dispatch_sync(_processingQueue, ^{
        self->_frameCount = 0;
        self->_lastFrame = nil;
        self->_isReceivingFrames = NO;
        self->_lastFrameTime = 0;
        self->_didLogFirstFrameDetails = NO;
        self->_cachedImage = nil;
        self->_lastFrameHash = 0;
        
        // Reiniciar array de tempos de processamento
        for (int i = 0; i < 10; i++) {
            self->_frameProcessingTimes[i] = 0.0f;
        }
        self->_frameTimeIndex = 0;
        
        writeLog(@"[WebRTCFrameConverter] Reset completo");
    });
}

#pragma mark - Configuração de adaptação

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    if (resolution.width == 0 || resolution.height == 0) {
        _adaptToTargetResolution = NO;
        writeLog(@"[WebRTCFrameConverter] Adaptação de resolução desativada");
        return;
    }
    
    _targetResolution = resolution;
    _adaptToTargetResolution = YES;
    
    // Limpar cache de imagem quando a resolução muda
    _cachedImage = nil;
    
    writeLog(@"[WebRTCFrameConverter] Resolução alvo definida para %dx%d (adaptação ativada)",
             resolution.width, resolution.height);
}

- (void)setTargetFrameRate:(float)frameRate {
    if (frameRate <= 0) {
        _adaptToTargetFrameRate = NO;
        writeLog(@"[WebRTCFrameConverter] Adaptação de taxa de quadros desativada");
        return;
    }
    
    int32_t timeScale = 90000; // Usar timeScale alto para precisão
    int32_t frameDuration = (int32_t)(timeScale / frameRate);
    _targetFrameDuration = CMTimeMake(frameDuration, timeScale);
    _adaptToTargetFrameRate = YES;
    
    writeLog(@"[WebRTCFrameConverter] Taxa de quadros alvo definida para %.1f fps (adaptação ativada)",
             frameRate);
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
    if (CGSizeEqualToSize(_lastFrameSize, size)) {
        return;
    }
    
    writeLog(@"[WebRTCFrameConverter] Tamanho do frame mudou: %@ -> %@",
             NSStringFromCGSize(_lastFrameSize),
             NSStringFromCGSize(size));
    
    _lastFrameSize = size;
    
    // Limpar cache quando o tamanho muda
    _cachedImage = nil;
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (!frame || frame.width == 0 || frame.height == 0) {
        return;
    }
    
    @try {
        NSTimeInterval startTime = CACurrentMediaTime();
        
        // Cálculo de hash simples do frame para detecção de mudanças
        uint64_t frameHash = frame.timeStampNs;
        if (frameHash == _lastFrameHash && _cachedImage != nil) {
            // Frame idêntico ao anterior, usar imagem em cache
            if (self.frameCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.frameCallback(self->_cachedImage);
                });
            }
            return;
        }
        
        _lastFrameHash = frameHash;
        
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
            // Caso contrário, usar a limitação padrão
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
        
        // Processamento em thread separada com tratamento de erros aprimorado
        dispatch_async(_processingQueue, ^{
            @autoreleasepool {
                @try {
                    NSTimeInterval conversionStartTime = CACurrentMediaTime();
                    
                    // Proteger contra frame nulo ou inválido
                    if (!frame || frame.width == 0 || frame.height == 0) {
                        dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                        return;
                    }
                    
                    // Determinar se precisa adaptar a resolução
                    UIImage *image;
                    if (self->_adaptToTargetResolution &&
                        self->_targetResolution.width > 0 &&
                        self->_targetResolution.height > 0) {
                        
                        // Converter e adaptar
                        image = [self adaptedImageFromVideoFrame:frame];
                    } else {
                        // Conversão normal
                        image = [self imageFromVideoFrame:frame];
                    }
                    
                    // Armazenar a imagem em cache
                    if (image) {
                        self->_cachedImage = image;
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
                        // Verificar se a imagem é válida
                        if (image.size.width > 0 && image.size.height > 0) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                // Verificar novamente se o callback ainda existe
                                if (self.frameCallback) {
                                    self.frameCallback(image);
                                }
                                dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                            });
                        } else {
                            writeLog(@"[WebRTCFrameConverter] Imagem convertida tem tamanho inválido: %@",
                                    NSStringFromCGSize(image.size));
                            dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                        }
                    } else {
                        writeLog(@"[WebRTCFrameConverter] Falha ao converter frame para UIImage");
                        dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                    }
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCFrameConverter] Exceção ao processar frame: %@", exception);
                    dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                }
            }
        });
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCFrameConverter] Exceção externa ao processar frame: %@", exception);
    }
}

- (void)setRenderFrame:(RTCVideoFrame *)frame {
    [self renderFrame:frame];
}

#pragma mark - Processamento de Frame

- (UIImage *)imageFromVideoFrame:(RTCVideoFrame *)frame {
    @autoreleasepool {
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
                
                // Verificar dimensões válidas
                size_t width = CVPixelBufferGetWidth(cvPixelBuffer);
                size_t height = CVPixelBufferGetHeight(cvPixelBuffer);
                if (width == 0 || height == 0) {
                    writeLog(@"[WebRTCFrameConverter] CVPixelBuffer tem dimensões inválidas: %zux%zu", width, height);
                    return nil;
                }
                
                // Bloquear o buffer para acesso com timeout
                CVReturn lockResult = CVPixelBufferLockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                if (lockResult != kCVReturnSuccess) {
                    writeLog(@"[WebRTCFrameConverter] Falha ao bloquear CVPixelBuffer: %d", (int)lockResult);
                    return nil;
                }
                
                UIImage *image = nil;
                
                @try {
                    // Usar abordagem mais eficiente com CIImage
                    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:cvPixelBuffer];
                    
                    if (!ciImage) {
                        writeLog(@"[WebRTCFrameConverter] Falha ao criar CIImage a partir do CVPixelBuffer");
                        CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                        return nil;
                    }
                    
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
                    
                    // Verificar contexto nulo e lidar com isso
                    if (!_ciContext) {
                        NSDictionary *options = @{
                            kCIContextUseSoftwareRenderer: @(NO),  // Usar GPU quando disponível
                            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
                            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
                        };
                        _ciContext = [CIContext contextWithOptions:options];
                        
                        if (!_ciContext) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar CIContext");
                            CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                            return nil;
                        }
                    }
                    
                    // Usar o contexto otimizado para criar CGImage
                    CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
                    
                    CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                    
                    if (!cgImage) {
                        writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage");
                        return nil;
                    }
                    
                    // Criar UIImage e verificar se foi criada com sucesso
                    image = [UIImage imageWithCGImage:cgImage];
                    CGImageRelease(cgImage);
                    
                    if (!image) {
                        writeLog(@"[WebRTCFrameConverter] Falha ao criar UIImage a partir de CGImage");
                        return nil;
                    }
                    
                    // Verificar tamanho final da imagem
                    if (image.size.width <= 0 || image.size.height <= 0) {
                        writeLog(@"[WebRTCFrameConverter] UIImage criada com dimensões inválidas: %@",
                                NSStringFromCGSize(image.size));
                        return nil;
                    }
                    
                    return image;
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCFrameConverter] Exceção ao processar CIImage: %@", exception);
                    
                    // Garantir que o buffer seja desbloqueado
                    CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                    return nil;
                }
            } else {
                writeLog(@"[WebRTCFrameConverter] Tipo de buffer não suportado: %@", NSStringFromClass([buffer class]));
                return nil;
            }
        } @catch (NSException *e) {
            writeLog(@"[WebRTCFrameConverter] Exceção ao converter frame para UIImage: %@", e);
            return nil;
        }
    }
}

#pragma mark - Adaptação para resolução alvo

- (UIImage *)adaptedImageFromVideoFrame:(RTCVideoFrame *)frame {
    @autoreleasepool {
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
        UIGraphicsBeginImageContextWithOptions(finalSize, NO, 1.0);
        
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
        
        // Log detalhado apenas ocasionalmente para evitar spam nos logs
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

#pragma mark - Métodos de Interface Pública

- (UIImage *)getLastFrameAsImage {
    @synchronized(self) {
        if (!_lastFrame) {
            return nil;
        }
        
        // Verificar se temos imagem em cache
        if (_cachedImage) {
            return _cachedImage;
        }
        
        if (_adaptToTargetResolution && _targetResolution.width > 0 && _targetResolution.height > 0) {
            return [self adaptedImageFromVideoFrame:_lastFrame];
        } else {
            return [self imageFromVideoFrame:_lastFrame];
        }
    }
}

- (NSDictionary *)getFrameProcessingStats {
    // Calcular tempo médio de processamento
    float averageTime = 0;
    for (int i = 0; i < 10; i++) {
        averageTime += _frameProcessingTimes[i];
    }
    averageTime /= 10.0;
    float fps = averageTime > 0 ? 1.0/averageTime : 0;
    
    // Calcular taxa de frames real com base no tempo entre frames
    float actualFps = 0;
    if (_frameCount > 1 && _lastFrameTime > 0) {
        NSTimeInterval now = CACurrentMediaTime();
        NSTimeInterval timeSinceLastFrame = now - _lastFrameTime;
        if (timeSinceLastFrame > 0) {
            actualFps = 1.0 / timeSinceLastFrame;
        }
    }
    
    // Informações sobre o último frame
    NSMutableDictionary *lastFrameInfo = [NSMutableDictionary dictionary];
    if (_lastFrame) {
        lastFrameInfo[@"width"] = @(_lastFrame.width);
        lastFrameInfo[@"height"] = @(_lastFrame.height);
        lastFrameInfo[@"rotation"] = @(_lastFrame.rotation);
        
        id<RTCVideoFrameBuffer> buffer = _lastFrame.buffer;
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
                lastFrameInfo[@"pixelFormat"] = [NSString stringWithUTF8String:formatChars];
            }
        }
    }
    
    return @{
        @"averageProcessingTimeMs": @(averageTime * 1000.0),
        @"estimatedFps": @(fps),
        @"actualFps": @(actualFps),
        @"frameCount": @(_frameCount),
        @"isReceivingFrames": @(_isReceivingFrames),
        @"adaptToTargetResolution": @(_adaptToTargetResolution),
        @"adaptToTargetFrameRate": @(_adaptToTargetFrameRate),
        @"targetResolution": @{
            @"width": @(_targetResolution.width),
            @"height": @(_targetResolution.height)
        },
        @"targetFrameRate": @(CMTimeGetSeconds(_targetFrameDuration) > 0 ?
                            1.0 / CMTimeGetSeconds(_targetFrameDuration) : 0),
        @"lastFrame": lastFrameInfo
    };
}

- (CMSampleBufferRef)getAdaptedSampleBuffer {
    // Primeiro obter um sample buffer normal
    CMSampleBufferRef originalBuffer = [self getOriginalSampleBuffer];
    if (!originalBuffer) return NULL;
    
    @try {
        // Verificar se precisamos adaptar para uma resolução diferente
        CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
        CMVideoDimensions originalDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        
        // Se já está na resolução correta, apenas retornar o buffer original
        if (originalDimensions.width == _targetResolution.width &&
            originalDimensions.height == _targetResolution.height) {
            return originalBuffer;
        }
        
        // Caso contrário, precisamos criar um novo buffer com a resolução adaptada
        // Converter o buffer original para uma UIImage primeiro
        UIImage *originalImage = [self imageFromVideoFrame:_lastFrame];
        if (!originalImage) {
            CFRelease(originalBuffer);
            return NULL;
        }
        
        // Adaptar a imagem para a resolução desejada
        UIImage *adaptedImage = [self adaptedImageFromVideoFrame:_lastFrame];
        if (!adaptedImage) {
            CFRelease(originalBuffer);
            return NULL;
        }
        
        // Criar um novo pixel buffer com as dimensões corretas
        CVPixelBufferRef adaptedPixelBuffer = NULL;
        CFDictionaryRef empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                                  &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
        NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                                [NSNumber numberWithBool:YES], kCVPixelBufferCGImageCompatibilityKey,
                                [NSNumber numberWithBool:YES], kCVPixelBufferCGBitmapContextCompatibilityKey,
                                empty, kCVPixelBufferIOSurfacePropertiesKey,
                                nil];
        CFRelease(empty);
        
        CVPixelBufferCreate(kCFAllocatorDefault,
                           _targetResolution.width,
                           _targetResolution.height,
                           kCVPixelFormatType_32BGRA,
                           (__bridge CFDictionaryRef)options,
                           &adaptedPixelBuffer);
        
        if (!adaptedPixelBuffer) {
            CFRelease(originalBuffer);
            return NULL;
        }
        
        // Renderizar a imagem adaptada no novo buffer
        CVPixelBufferLockBaseAddress(adaptedPixelBuffer, 0);
        
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(adaptedPixelBuffer),
                                                   _targetResolution.width,
                                                   _targetResolution.height,
                                                   8,
                                                   CVPixelBufferGetBytesPerRow(adaptedPixelBuffer),
                                                   colorSpace,
                                                   kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGColorSpaceRelease(colorSpace);
        
        if (!context) {
            CVPixelBufferUnlockBaseAddress(adaptedPixelBuffer, 0);
            CVPixelBufferRelease(adaptedPixelBuffer);
            CFRelease(originalBuffer);
            return NULL;
        }
        
        CGContextDrawImage(context, CGRectMake(0, 0, _targetResolution.width, _targetResolution.height),
                          adaptedImage.CGImage);
        CGContextRelease(context);
        
        CVPixelBufferUnlockBaseAddress(adaptedPixelBuffer, 0);
        
        // Criar um novo format description
        CMVideoFormatDescriptionRef adaptedFormatDescription = NULL;
        OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                     adaptedPixelBuffer,
                                                                     &adaptedFormatDescription);
        
        if (status != 0) {
            CVPixelBufferRelease(adaptedPixelBuffer);
            CFRelease(originalBuffer);
            return NULL;
        }
        
        // Obter timing info do buffer original
        CMSampleTimingInfo timing;
        CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &timing);
        
        // Criar o novo sample buffer
        CMSampleBufferRef adaptedBuffer = NULL;
        status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                                 adaptedPixelBuffer,
                                                 true,
                                                 NULL,
                                                 NULL,
                                                 adaptedFormatDescription,
                                                 &timing,
                                                 &adaptedBuffer);
        
        // Liberar recursos temporários
        CVPixelBufferRelease(adaptedPixelBuffer);
        CFRelease(adaptedFormatDescription);
        CFRelease(originalBuffer);
        
        if (status != 0) {
            return NULL;
        }
        
        return adaptedBuffer;
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCFrameConverter] Exceção em getAdaptedSampleBuffer: %@", exception);
        if (originalBuffer) {
            CFRelease(originalBuffer);
        }
        return NULL;
    }
}

@end
