#import "WebRTCFrameConverter.h"
#import "logger.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

@implementation WebRTCFrameConverter {
    RTCVideoFrame *_lastFrame;
    CGColorSpaceRef _colorSpace;
    CGColorSpaceRef _yuvColorSpace;
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
    IOSPixelFormat _detectedPixelFormat;
    NSString *_processingMode;
    
    // Variáveis para adaptação automática
    CMVideoDimensions _targetResolution;
    CMTime _targetFrameDuration;
    BOOL _adaptToTargetResolution;
    BOOL _adaptToTargetFrameRate;
    dispatch_semaphore_t _frameProcessingSemaphore;
    
    // Configurações de formato nativo do iOS
    OSType _nativeCameraFormat;
    CMVideoDimensions _nativeCameraResolution;
    BOOL _adaptToNativeFormat;
    
    // Cache de imagem para otimização de performance
    UIImage *_cachedImage;
    uint64_t _lastFrameHash;
    CMSampleBufferRef _cachedSampleBuffer;
    uint64_t _cachedSampleBufferHash;
    OSType _cachedSampleBufferFormat;
    
    // Novos contadores para rastreamento de recursos
    NSUInteger _totalSampleBuffersCreated;
    NSUInteger _totalSampleBuffersReleased;
    NSUInteger _totalPixelBuffersLocked;
    NSUInteger _totalPixelBuffersUnlocked;
    BOOL _isShuttingDown;
    
    // Timestamp do último aviso sobre vazamento
    NSTimeInterval _lastLeakWarningTime;
    
    // Para evitar uso excessivo de memória
    NSUInteger _maxCachedSampleBuffers;
    NSMutableDictionary<NSNumber *, NSValue *> *_sampleBufferCache; // Map de formato para sample buffer
}

@synthesize frameCount = _frameCount;
@synthesize detectedPixelFormat = _detectedPixelFormat;
@synthesize processingMode = _processingMode;

#pragma mark - Inicialização e Cleanup

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
        _yuvColorSpace = CGColorSpaceCreateDeviceRGB(); // Usando RGB em vez de YUV // Para processamento YUV
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
        _detectedPixelFormat = IOSPixelFormatUnknown;
        _processingMode = @"unknown";
        
        // Inicialização de adaptação automática
        _targetResolution.width = 0;
        _targetResolution.height = 0;
        _targetFrameDuration = CMTimeMake(1, 30); // Default 30 fps
        _adaptToTargetResolution = NO;
        _adaptToTargetFrameRate = NO;
        _frameProcessingSemaphore = dispatch_semaphore_create(1);
        
        // Inicializar formato de câmera nativo
        _nativeCameraFormat = 0; // Inicialmente desconhecido
        _nativeCameraResolution.width = 0;
        _nativeCameraResolution.height = 0;
        _adaptToNativeFormat = NO;
        
        // Inicializar array de tempos de processamento
        for (int i = 0; i < 10; i++) {
            _frameProcessingTimes[i] = 0.0f;
        }
        _frameTimeIndex = 0;
        
        // Inicializar contadores de recursos
        _totalSampleBuffersCreated = 0;
        _totalSampleBuffersReleased = 0;
        _totalPixelBuffersLocked = 0;
        _totalPixelBuffersUnlocked = 0;
        _isShuttingDown = NO;
        _lastLeakWarningTime = 0;
        
        // Cache otimizado
        _maxCachedSampleBuffers = 3; // Máximo 3 sample buffers em cache (um por formato)
        _sampleBufferCache = [NSMutableDictionary dictionaryWithCapacity:_maxCachedSampleBuffers];
        
        // Registrar para notificação de baixa memória para liberar cache
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleLowMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
        writeLog(@"[WebRTCFrameConverter] Inicializado com suporte otimizado para formatos iOS");
    }
    return self;
}

- (void)dealloc {
    // Marcar que estamos desligando para não emitir warnings desnecessários
    _isShuttingDown = YES;
    
    // Remover observadores de notificação
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
    
    if (_yuvColorSpace) {
        CGColorSpaceRelease(_yuvColorSpace);
        _yuvColorSpace = NULL;
    }
    
    // Limpar cache de CMSampleBuffer
    [self clearSampleBufferCache];
    
    // Verificar se há vazamentos potenciais
    if (_totalSampleBuffersCreated != _totalSampleBuffersReleased) {
        writeWarningLog(@"[WebRTCFrameConverter] Possível vazamento de recursos ao desalocar: %lu sample buffers criados, %lu liberados",
                       (unsigned long)_totalSampleBuffersCreated,
                       (unsigned long)_totalSampleBuffersReleased);
    }
    
    if (_totalPixelBuffersLocked != _totalPixelBuffersUnlocked) {
        writeWarningLog(@"[WebRTCFrameConverter] Possível vazamento de CVPixelBuffer: %lu bloqueios, %lu desbloqueios",
                       (unsigned long)_totalPixelBuffersLocked,
                       (unsigned long)_totalPixelBuffersUnlocked);
    }
    
    // CIContext é tratado pelo ARC
    _cachedImage = nil;
    
    writeLog(@"[WebRTCFrameConverter] Objeto desalocado, recursos liberados");
}

#pragma mark - Gestão de Memória e Cache

- (void)clearSampleBufferCache {
    @synchronized(self) {
        // Liberar todos os sample buffers em cache
        [_sampleBufferCache enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSValue *value, BOOL *stop) {
            CMSampleBufferRef buffer = NULL;
            [value getValue:&buffer];
            if (buffer) {
                CFRelease(buffer);
                self->_totalSampleBuffersReleased++;
            }
        }];
        
        [_sampleBufferCache removeAllObjects];
        
        // Limpar sample buffer principal se existir
        if (_cachedSampleBuffer) {
            CFRelease(_cachedSampleBuffer);
            _cachedSampleBuffer = NULL;
            _totalSampleBuffersReleased++;
        }
        
        writeLog(@"[WebRTCFrameConverter] Cache de sample buffers limpo");
    }
}

- (void)handleLowMemoryWarning {
    writeLog(@"[WebRTCFrameConverter] Aviso de memória baixa recebido, liberando recursos");
    [self clearSampleBufferCache];
    _cachedImage = nil;
}

- (void)checkResourceBalance {
    // Realizar esta verificação apenas periodicamente para evitar spam no log
    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastLeakWarningTime < 10.0) return; // Verificar no máximo a cada 10 segundos
    
    @synchronized(self) {
        // Verificar se há um desequilíbrio significativo em recursos
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        
        if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
            writeWarningLog(@"[WebRTCFrameConverter] Possível vazamento de recursos detectado - SampleBuffers: %ld não liberados, PixelBuffers: %ld não desbloqueados",
                           (long)sampleBufferDiff,
                           (long)pixelBufferDiff);
            
            // Tentar recuperar liberando o cache
            [self clearSampleBufferCache];
            
            _lastLeakWarningTime = now;
        }
    }
}

#pragma mark - Getters e Propriedades

- (BOOL)isReceivingFrames {
    return _isReceivingFrames;
}

#pragma mark - Métodos de Reset e Configuração

- (void)reset {
    dispatch_sync(_processingQueue, ^{
        self->_frameCount = 0;
        self->_lastFrame = nil;
        self->_isReceivingFrames = NO;
        self->_lastFrameTime = 0;
        self->_didLogFirstFrameDetails = NO;
        self->_cachedImage = nil;
        self->_lastFrameHash = 0;
        self->_detectedPixelFormat = IOSPixelFormatUnknown;
        
        // Limpar cache
        [self clearSampleBufferCache];
        
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
    
    // Limpar cache de sample buffers
    [self clearSampleBufferCache];
    
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

- (void)adaptToNativeCameraFormat:(OSType)format resolution:(CMVideoDimensions)resolution {
    _nativeCameraFormat = format;
    _nativeCameraResolution = resolution;
    _adaptToNativeFormat = YES;
    
    // Detectar formato de pixel para notificação e otimização
    _detectedPixelFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:format];
    
    // Limpar caches
    _cachedImage = nil;
    [self clearSampleBufferCache];
    
    writeLog(@"[WebRTCFrameConverter] Adaptando para formato nativo: %s (%dx%d), IOSPixelFormat: %@",
             [self formatTypeToString:format],
             resolution.width, resolution.height,
             [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat]);
}

#pragma mark - Métodos de classe (Conversão de tipos de formato)

+ (IOSPixelFormat)pixelFormatFromCVFormat:(OSType)cvFormat {
    switch (cvFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return IOSPixelFormat420f;
            
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return IOSPixelFormat420v;
            
        case kCVPixelFormatType_32BGRA:
            return IOSPixelFormatBGRA;
            
        default:
            return IOSPixelFormatUnknown;
    }
}

+ (OSType)cvFormatFromPixelFormat:(IOSPixelFormat)iosFormat {
    switch (iosFormat) {
        case IOSPixelFormat420f:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
            
        case IOSPixelFormat420v:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            
        case IOSPixelFormatBGRA:
            return kCVPixelFormatType_32BGRA;
            
        default:
            return kCVPixelFormatType_32BGRA; // Default para compatibilidade
    }
}

+ (NSString *)stringFromPixelFormat:(IOSPixelFormat)format {
    switch (format) {
        case IOSPixelFormat420f:
            return @"YUV 4:2:0 Full-Range (420f)";
            
        case IOSPixelFormat420v:
            return @"YUV 4:2:0 Video-Range (420v)";
            
        case IOSPixelFormatBGRA:
            return @"BGRA 32-bit";
            
        default:
            return @"Desconhecido";
    }
}

- (const char *)formatTypeToString:(OSType)format {
    char formatStr[5] = {0};
    formatStr[0] = (format >> 24) & 0xFF;
    formatStr[1] = (format >> 16) & 0xFF;
    formatStr[2] = (format >> 8) & 0xFF;
    formatStr[3] = format & 0xFF;
    formatStr[4] = 0;
    
    static char result[5];
    memcpy(result, formatStr, 5);
    return result;
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
    [self clearSampleBufferCache];
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
                    @try {
                        self.frameCallback(self->_cachedImage);
                    } @catch (NSException *e) {
                        writeLog(@"[WebRTCFrameConverter] Exceção ao chamar callback: %@", e);
                    }
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
        
        // Analisar e registrar o tipo de buffer para otimização
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
            CVPixelBufferRef cvBuffer = pixelBuffer.pixelBuffer;
            
            if (cvBuffer) {
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(cvBuffer);
                _detectedPixelFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:pixelFormat];
                
                // Determinar modo de processamento
                if (CVPixelBufferGetIOSurface(cvBuffer)) {
                    _processingMode = @"hardware-accelerated";
                } else {
                    _processingMode = @"software";
                }
                
                // Log detalhado para o primeiro frame e periodicamente
                if (!_didLogFirstFrameDetails || _frameCount % 300 == 0) {
                    char formatChars[5] = {
                        (char)((pixelFormat >> 24) & 0xFF),
                        (char)((pixelFormat >> 16) & 0xFF),
                        (char)((pixelFormat >> 8) & 0xFF),
                        (char)(pixelFormat & 0xFF),
                        0
                    };
                    
                    writeLog(@"[WebRTCFrameConverter] Frame #%d: %dx%d, formato de pixel: %s (IOSPixelFormat: %@), modo: %@",
                            _frameCount,
                            (int)frame.width,
                            (int)frame.height,
                            formatChars,
                            [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat],
                            _processingMode);
                    
                    _didLogFirstFrameDetails = YES;
                }
            }
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
                        
                        writeLog(@"[WebRTCFrameConverter] Tempo médio de processamento: %.2f ms, FPS estimado: %.1f, formato: %@",
                                averageTime * 1000.0,
                                averageTime > 0 ? 1.0/averageTime : 0,
                                [WebRTCFrameConverter stringFromPixelFormat:self->_detectedPixelFormat]);
                        
                        self->_lastPerformanceLogTime = CACurrentMediaTime();
                        
                        // Verificar recursos
                        [self checkResourceBalance];
                    }
                    
                    if (image) {
                        // Verificar se a imagem é válida
                        if (image.size.width > 0 && image.size.height > 0) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                // Verificar novamente se o callback ainda existe
                                @try {
                                    if (self.frameCallback) {
                                        self.frameCallback(image);
                                    }
                                } @catch (NSException *e) {
                                    writeLog(@"[WebRTCFrameConverter] Exceção ao chamar callback: %@", e);
                                } @finally {
                                    dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                                }
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
                
                // Determinar o formato e otimizar conversão com base nele
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(cvPixelBuffer);
                IOSPixelFormat iosFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:pixelFormat];
                
                // Bloquear o buffer para acesso com timeout
                CVReturn lockResult = CVPixelBufferLockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                if (lockResult != kCVReturnSuccess) {
                    writeLog(@"[WebRTCFrameConverter] Falha ao bloquear CVPixelBuffer: %d", (int)lockResult);
                    return nil;
                }
                
                // Incrementar contador de bloqueios
                _totalPixelBuffersLocked++;
                
                UIImage *image = nil;
                
                @try {
                    // Verificar se estamos lidando com formatos YUV ou BGRA
                    if (iosFormat == IOSPixelFormat420f || iosFormat == IOSPixelFormat420v) {
                        // Processamento otimizado para formatos YUV
                        // Para YUV, o CIImage já lida com a conversão de forma eficiente
                        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:cvPixelBuffer];
                        
                        if (!ciImage) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar CIImage a partir do CVPixelBuffer YUV");
                            CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                            _totalPixelBuffersUnlocked++;
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
                                _totalPixelBuffersUnlocked++;
                                return nil;
                            }
                        }
                        
                        // Usar o contexto otimizado para criar CGImage
                        CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
                        
                        // Desbloquear o buffer antes de continuar o processamento
                        CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                        _totalPixelBuffersUnlocked++;
                        
                        if (!cgImage) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage de YUV");
                            return nil;
                        }
                        
                        // Criar UIImage e verificar se foi criada com sucesso
                        image = [UIImage imageWithCGImage:cgImage];
                        CGImageRelease(cgImage);
                    }
                    else if (iosFormat == IOSPixelFormatBGRA) {
                        // Processamento otimizado para BGRA (32-bit)
                        // Para BGRA, podemos usar uma abordagem mais direta
                        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(cvPixelBuffer);
                        void *baseAddress = CVPixelBufferGetBaseAddress(cvPixelBuffer);
                        
                        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                        CGContextRef cgContext = CGBitmapContextCreate(baseAddress,
                                                                     width,
                                                                     height,
                                                                     8,
                                                                     bytesPerRow,
                                                                     colorSpace,
                                                                     kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                        
                        CGColorSpaceRelease(colorSpace);
                        
                        if (!cgContext) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar CGContext para BGRA");
                            CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                            _totalPixelBuffersUnlocked++;
                            return nil;
                        }
                        
                        CGImageRef cgImage = CGBitmapContextCreateImage(cgContext);
                        CGContextRelease(cgContext);
                        
                        // Desbloquear o buffer após criar o CGImage
                        CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                        _totalPixelBuffersUnlocked++;
                        
                        if (!cgImage) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage de BGRA");
                            return nil;
                        }
                        
                        // Aplicar rotação se necessário
                        if (frame.rotation != RTCVideoRotation_0) {
                            UIImage *originalImage = [UIImage imageWithCGImage:cgImage];
                            CGImageRelease(cgImage);
                            
                            UIGraphicsBeginImageContextWithOptions(CGSizeMake(originalImage.size.height, originalImage.size.width), NO, originalImage.scale);
                            CGContextRef context = UIGraphicsGetCurrentContext();
                            
                            // Transformação para rotação
                            switch (frame.rotation) {
                                case RTCVideoRotation_90:
                                    CGContextTranslateCTM(context, 0, originalImage.size.height);
                                    CGContextRotateCTM(context, -M_PI_2);
                                    CGContextDrawImage(context, CGRectMake(0, 0, originalImage.size.width, originalImage.size.height), originalImage.CGImage);
                                    break;
                                case RTCVideoRotation_180:
                                    CGContextTranslateCTM(context, originalImage.size.width, originalImage.size.height);
                                    CGContextRotateCTM(context, M_PI);
                                    CGContextDrawImage(context, CGRectMake(0, 0, originalImage.size.width, originalImage.size.height), originalImage.CGImage);
                                    break;
                                case RTCVideoRotation_270:
                                    CGContextTranslateCTM(context, originalImage.size.width, 0);
                                    CGContextRotateCTM(context, M_PI_2);
                                    CGContextDrawImage(context, CGRectMake(0, 0, originalImage.size.width, originalImage.size.height), originalImage.CGImage);
                                    break;
                                default:
                                    break;
                            }
                            
                            image = UIGraphicsGetImageFromCurrentImageContext();
                            UIGraphicsEndImageContext();
                        } else {
                            image = [UIImage imageWithCGImage:cgImage];
                            CGImageRelease(cgImage);
                        }
                    }
                    else {
                        // Formato desconhecido, usar abordagem genérica com CIImage
                        writeLog(@"[WebRTCFrameConverter] Usando método genérico para formato desconhecido");
                        
                        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:cvPixelBuffer];
                        
                        if (!ciImage) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar CIImage a partir do CVPixelBuffer");
                            CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                            _totalPixelBuffersUnlocked++;
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
                                _totalPixelBuffersUnlocked++;
                                return nil;
                            }
                        }
                        
                        // Usar o contexto otimizado para criar CGImage
                        CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
                        
                        // Desbloquear o buffer após criar o CGImage
                        CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                        _totalPixelBuffersUnlocked++;
                        
                        if (!cgImage) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage");
                            return nil;
                        }
                        
                        // Criar UIImage e verificar se foi criada com sucesso
                        image = [UIImage imageWithCGImage:cgImage];
                        CGImageRelease(cgImage);
                    }
                    
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
                    _totalPixelBuffersUnlocked++;
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
    return [self getLatestSampleBufferWithFormat:_detectedPixelFormat];
}

- (CMSampleBufferRef)getLatestSampleBufferWithFormat:(IOSPixelFormat)pixelFormat {
    @try {
        // Se não tivermos um frame, retornar nulo
        if (!_lastFrame) {
            return NULL;
        }
        
        // Converter formato IOSPixelFormat para OSType
        OSType cvFormat = [WebRTCFrameConverter cvFormatFromPixelFormat:pixelFormat];
        
        // Criar chave para cache
        NSNumber *formatKey = @(cvFormat);
        
        // Verificar se temos um buffer em cache com o formato correto
        @synchronized(self) {
            // Verificar no cache individual
            if (_cachedSampleBuffer && _cachedSampleBufferHash == _lastFrameHash && _cachedSampleBufferFormat == cvFormat) {
                // Se já temos um buffer em cache para este frame e formato, retornar uma cópia do cache
                CMSampleBufferRef outputBuffer = NULL;
                OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, _cachedSampleBuffer, &outputBuffer);
                if (status != noErr) {
                    writeErrorLog(@"[WebRTCFrameConverter] Erro ao criar cópia do CMSampleBuffer: %d", (int)status);
                    return NULL;
                }
                return outputBuffer;
            }
            
            // Verificar no cache geral de formatos
            NSValue *cachedBufferValue = _sampleBufferCache[formatKey];
            if (cachedBufferValue) {
                CMSampleBufferRef cachedBuffer = NULL;
                [cachedBufferValue getValue:&cachedBuffer];
                
                if (cachedBuffer) {
                    // Verificar se o buffer é do frame atual
                    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(cachedBuffer);
                    if (formatDesc) {
                        // Criar uma cópia para retornar
                        CMSampleBufferRef outputBuffer = NULL;
                        OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, cachedBuffer, &outputBuffer);
                        if (status == noErr) {
                            // Atualizar o timestamp antes de retornar
                            CMSampleTimingInfo timing;
                            timing.duration = kCMTimeInvalid;
                            timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
                            timing.decodeTimeStamp = kCMTimeInvalid;
                            
                            // Atualizar timing info para sincronizar com tempo atual
                            status = CMSampleBufferSetOutputPresentationTimeStamp(outputBuffer, timing.presentationTimeStamp);
                            if (status != noErr) {
                                writeWarningLog(@"[WebRTCFrameConverter] Aviso: não foi possível atualizar timestamp: %d", (int)status);
                            }
                            
                            return outputBuffer;
                        }
                    }
                }
            }
        }
        
        // Caso contrário, criar um novo buffer
        CMSampleBufferRef sampleBuffer = [self createSampleBufferWithFormat:cvFormat];
        
        // Armazenar na cache se criado com sucesso
        if (sampleBuffer) {
            @synchronized(self) {
                // Liberar o buffer anterior se existir
                if (_cachedSampleBuffer) {
                    CFRelease(_cachedSampleBuffer);
                    _cachedSampleBuffer = NULL;
                    _totalSampleBuffersReleased++;
                }
                
                // Armazenar uma cópia para cache
                OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &_cachedSampleBuffer);
                if (status != noErr) {
                    writeErrorLog(@"[WebRTCFrameConverter] Erro ao criar cópia para cache: %d", (int)status);
                    // Ainda podemos retornar o buffer original mesmo se o cache falhar
                } else {
                    _cachedSampleBufferHash = _lastFrameHash;
                    _cachedSampleBufferFormat = cvFormat;
                    
                    // Também adicionar ao cache geral - primeiro criar uma cópia para o cache de formatos
                    CMSampleBufferRef formatCacheBuffer = NULL;
                    status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &formatCacheBuffer);
                    
                    if (status == noErr && formatCacheBuffer) {
                        // Liberar o buffer anterior para este formato se existir
                        NSValue *oldValue = _sampleBufferCache[formatKey];
                        if (oldValue) {
                            CMSampleBufferRef oldBuffer = NULL;
                            [oldValue getValue:&oldBuffer];
                            if (oldBuffer) {
                                CFRelease(oldBuffer);
                                _totalSampleBuffersReleased++;
                            }
                        }
                        
                        // Armazenar o novo buffer
                        NSValue *newValue = [NSValue valueWithBytes:&formatCacheBuffer objCType:@encode(CMSampleBufferRef)];
                        _sampleBufferCache[formatKey] = newValue;
                    }
                }
            }
        }
        
        return sampleBuffer;
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCFrameConverter] Exceção em getLatestSampleBufferWithFormat: %@", exception);
        return NULL;
    }
}

- (CMSampleBufferRef)createSampleBufferWithFormat:(OSType)format {
    if (!_lastFrame) return NULL;
    
    id<RTCVideoFrameBuffer> buffer = _lastFrame.buffer;
    
    // Verificar se temos um CVPixelBuffer
    if (![buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        writeLog(@"[WebRTCFrameConverter] createSampleBufferWithFormat: Buffer não é CVPixelBuffer");
        return NULL;
    }
    
    RTCCVPixelBuffer *rtcPixelBuffer = (RTCCVPixelBuffer *)buffer;
    CVPixelBufferRef pixelBuffer = rtcPixelBuffer.pixelBuffer;
    
    if (!pixelBuffer) {
        writeLog(@"[WebRTCFrameConverter] createSampleBufferWithFormat: pixelBuffer é NULL");
        return NULL;
    }
    
    // Verificar formato do pixel
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    
    // Registrar o formato para diagnóstico
    char sourceFormatChars[5] = {
        (char)((sourceFormat >> 24) & 0xFF),
        (char)((sourceFormat >> 16) & 0xFF),
        (char)((sourceFormat >> 8) & 0xFF),
        (char)(sourceFormat & 0xFF),
        0
    };
    
    char targetFormatChars[5] = {
        (char)((format >> 24) & 0xFF),
        (char)((format >> 16) & 0xFF),
        (char)((format >> 8) & 0xFF),
        (char)(format & 0xFF),
        0
    };
    
    writeVerboseLog(@"[WebRTCFrameConverter] Formato de pixel origem: %s (0x%08X), destino: %s (0x%08X)",
                  sourceFormatChars, (unsigned int)sourceFormat,
                  targetFormatChars, (unsigned int)format);
    
    // Se o formato já for o desejado, podemos usar diretamente
    if (sourceFormat == format) {
        // Podemos usar diretamente o buffer original
        return [self createSampleBufferFromPixelBuffer:pixelBuffer];
    }
    
    // Caso contrário, precisamos converter para o formato desejado
    // Criar um novo buffer com o formato solicitado
    CVPixelBufferRef convertedBuffer = NULL;
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(format),
        (NSString *)kCVPixelBufferWidthKey: @(CVPixelBufferGetWidth(pixelBuffer)),
        (NSString *)kCVPixelBufferHeightKey: @(CVPixelBufferGetHeight(pixelBuffer)),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                        CVPixelBufferGetWidth(pixelBuffer),
                                        CVPixelBufferGetHeight(pixelBuffer),
                                        format,
                                        (__bridge CFDictionaryRef)pixelBufferAttributes,
                                        &convertedBuffer);
    
    if (result != kCVReturnSuccess || !convertedBuffer) {
        writeErrorLog(@"[WebRTCFrameConverter] Falha ao criar buffer compatível: %d", result);
        return NULL;
    }
    
    // Converter o conteúdo usando CIImage/CIContext para máxima compatibilidade
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    [_ciContext render:ciImage toCVPixelBuffer:convertedBuffer];
    
    // Criar CMSampleBuffer com o buffer convertido
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:convertedBuffer];
    
    // Liberar o buffer convertido
    CVPixelBufferRelease(convertedBuffer);
    
    return sampleBuffer;
}

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NULL;
    
    // Incrementar contador de buffers criados
    _totalSampleBuffersCreated++;
    
    // Criar um CMVideoFormatDescription a partir do CVPixelBuffer
    CMVideoFormatDescriptionRef formatDescription;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    
    if (status != 0) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMVideoFormatDescription: %d", (int)status);
        return NULL;
    }
    
    // Timestamp para o sample buffer - IMPORTANTE: usar relógio do host para sincronização
    CMTimeScale timeScale = 1000000000; // Nanosegundos
    CMTime timestamp = CMClockGetTime(CMClockGetHostTimeClock()); // Usar relógio do sistema
    
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
                lastFrameInfo[@"iosFormat"] = [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat];
            }
        }
    }
    
    // Estatísticas de gerenciamento de recursos
    NSMutableDictionary *resourceStats = [NSMutableDictionary dictionary];
    resourceStats[@"sampleBuffersCreated"] = @(_totalSampleBuffersCreated);
    resourceStats[@"sampleBuffersReleased"] = @(_totalSampleBuffersReleased);
    resourceStats[@"pixelBuffersLocked"] = @(_totalPixelBuffersLocked);
    resourceStats[@"pixelBuffersUnlocked"] = @(_totalPixelBuffersUnlocked);
    resourceStats[@"sampleBufferCacheSize"] = @(_sampleBufferCache.count);
    
    // Verificar se há um desequilíbrio significativo em recursos
    NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
    NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
    resourceStats[@"sampleBufferDiff"] = @(sampleBufferDiff);
    resourceStats[@"pixelBufferDiff"] = @(pixelBufferDiff);
    
    // Adicionar status geral de recursos
    if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
        resourceStats[@"resourceStatus"] = @"WARNING: Potencial vazamento detectado";
    } else {
        resourceStats[@"resourceStatus"] = @"OK";
    }
    
    return @{
        @"averageProcessingTimeMs": @(averageTime * 1000.0),
        @"estimatedFps": @(fps),
        @"actualFps": @(actualFps),
        @"frameCount": @(_frameCount),
        @"isReceivingFrames": @(_isReceivingFrames),
        @"adaptToTargetResolution": @(_adaptToTargetResolution),
        @"adaptToTargetFrameRate": @(_adaptToTargetFrameRate),
        @"adaptToNativeFormat": @(_adaptToNativeFormat),
        @"targetResolution": @{
            @"width": @(_targetResolution.width),
            @"height": @(_targetResolution.height)
        },
        @"targetFrameRate": @(CMTimeGetSeconds(_targetFrameDuration) > 0 ?
                            1.0 / CMTimeGetSeconds(_targetFrameDuration) : 0),
        @"processingMode": _processingMode,
        @"detectedPixelFormat": [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat],
        @"lastFrame": lastFrameInfo,
        @"resourceManagement": resourceStats
    };
}

- (void)performSafeCleanup {
    writeLog(@"[WebRTCFrameConverter] Realizando limpeza segura de recursos");
    
    @synchronized(self) {
        // Limpar cache de imagem
        _cachedImage = nil;
        
        // Limpar cache de sample buffers
        [self clearSampleBufferCache];
        
        // Verificar se há desequilíbrio em recursos e registrar
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        
        if (sampleBufferDiff > 0 || pixelBufferDiff > 0) {
            writeWarningLog(@"[WebRTCFrameConverter] Possíveis recursos não liberados: %ld sample buffers, %ld pixel buffers",
                           (long)sampleBufferDiff, (long)pixelBufferDiff);
        }
    }
}

@end
