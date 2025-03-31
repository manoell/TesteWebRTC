#import "WebRTCCameraAdapter.h"
#import "logger.h"

@implementation WebRTCCameraAdapter {
    AVCaptureVideoOrientation _currentOrientation;
    BOOL _videoMirrored;
    CMVideoDimensions _currentDimensions;
    OSType _currentFormat;
    NSTimeInterval _lastFrameTime;
    uint64_t _framesProcessed;
    uint64_t _framesDropped;
}

#pragma mark - Singleton Implementation

+ (instancetype)sharedInstance {
    static WebRTCCameraAdapter *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        _active = NO;
        _webRTCManager = nil;
        _currentOrientation = AVCaptureVideoOrientationPortrait;
        _videoMirrored = NO;
        _currentDimensions.width = 0;
        _currentDimensions.height = 0;
        _currentFormat = 0;
        _lastFrameTime = 0;
        _framesProcessed = 0;
        _framesDropped = 0;
        
        writeLog(@"[WebRTCCameraAdapter] Inicializado");
    }
    return self;
}

#pragma mark - Lifecycle Methods

- (void)startWithManager:(WebRTCManager *)manager {
    if (_active) {
        writeLog(@"[WebRTCCameraAdapter] Já está ativo, ignorando chamada");
        return;
    }
    
    _webRTCManager = manager;
    _active = YES;
    
    // Resetar contadores de frames
    _framesProcessed = 0;
    _framesDropped = 0;
    
    writeLog(@"[WebRTCCameraAdapter] Iniciado com WebRTCManager");
}

- (void)stop {
    if (!_active) {
        return;
    }
    
    _active = NO;
    
    // Não liberamos o WebRTCManager aqui, pois ele pode ser usado por outros componentes
    
    writeLog(@"[WebRTCCameraAdapter] Parado");
}

#pragma mark - Frame Adaptation

- (CMSampleBufferRef)getAdaptedFrameForOriginal:(CMSampleBufferRef)originalBuffer {
    if (!_active || !_webRTCManager || !originalBuffer) {
        return NULL;
    }
    
    // Verifica se o WebRTCManager está recebendo frames
    if (!_webRTCManager.isReceivingFrames) {
        _framesDropped++;
        return NULL;
    }
    
    // Obtém os detalhes do formato original para adaptação precisa
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(originalBuffer);
    if (!formatDesc) {
        writeLog(@"[WebRTCCameraAdapter] Formato de descrição não disponível no buffer original");
        _framesDropped++;
        return NULL;
    }
    
    // Obtém formato e dimensões
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc);
    OSType format = CMFormatDescriptionGetMediaSubType(formatDesc);
    
    // Adapta o WebRTCManager para o formato atual se mudar
    if (_currentFormat != format ||
        _currentDimensions.width != dimensions.width ||
        _currentDimensions.height != dimensions.height) {
        
        [self adaptToCameraFormat:format dimensions:dimensions];
    }
    
    // Obtém um frame adaptado do WebRTCManager
    CMSampleBufferRef adaptedBuffer = [_webRTCManager getLatestVideoSampleBufferWithOriginalMetadata:originalBuffer];
    
    if (adaptedBuffer) {
        _framesProcessed++;
        _lastFrameTime = CACurrentMediaTime();
        return adaptedBuffer;
    } else {
        _framesDropped++;
        return NULL;
    }
}

- (BOOL)updatePreviewLayer:(AVSampleBufferDisplayLayer *)previewLayer {
    if (!_active || !_webRTCManager || !previewLayer || !previewLayer.readyForMoreMediaData) {
        return NO;
    }
    
    // Verifica se o WebRTCManager está recebendo frames
    if (!_webRTCManager.isReceivingFrames) {
        return NO;
    }
    
    // Obtém o último frame do WebRTC
    CMSampleBufferRef buffer = [_webRTCManager getLatestVideoSampleBuffer];
    if (!buffer) {
        return NO;
    }
    
    // Limpa a fila existente e adiciona o novo frame
    [previewLayer flush];
    
    // Cria uma cópia para o preview
    CMSampleBufferRef copyBuffer = NULL;
    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, buffer, &copyBuffer);
    
    if (status == noErr && copyBuffer != NULL) {
        [previewLayer enqueueSampleBuffer:copyBuffer];
        CFRelease(copyBuffer);
        return YES;
    }
    
    return NO;
}

#pragma mark - Configuration Methods

- (void)adaptToCameraFormat:(OSType)format dimensions:(CMVideoDimensions)dimensions {
    _currentFormat = format;
    _currentDimensions = dimensions;
    
    writeLog(@"[WebRTCCameraAdapter] Adaptando para formato da câmera - Formato: %d, Dimensões: %dx%d",
             (int)format, dimensions.width, dimensions.height);
    
    // Conversor de formato OSType para IOSPixelFormat
    IOSPixelFormat iosFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:format];
    writeLog(@"[WebRTCCameraAdapter] Adaptando para formato da câmera - Formato: %d (%@), Dimensões: %dx%d",
             (int)format, [WebRTCFrameConverter stringFromPixelFormat:iosFormat],
             dimensions.width, dimensions.height);
    
    // Configura o WebRTCManager com os novos parâmetros
    if (_webRTCManager && _webRTCManager.frameConverter) {
        [_webRTCManager.frameConverter adaptToNativeCameraFormat:format resolution:dimensions];
        [_webRTCManager setTargetResolution:dimensions];
    }
}

- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation {
    if (_currentOrientation == orientation) {
        return;
    }
    
    _currentOrientation = orientation;
    
    writeLog(@"[WebRTCCameraAdapter] Orientação atualizada: %d", (int)orientation);
    
    // Atualiza a orientação no WebRTCManager
    if (_webRTCManager) {
        [_webRTCManager adaptOutputToVideoOrientation:(int)orientation];
    }
}

- (void)setVideoMirrored:(BOOL)mirrored {
    if (_videoMirrored == mirrored) {
        return;
    }
    
    _videoMirrored = mirrored;
    
    writeLog(@"[WebRTCCameraAdapter] Espelhamento atualizado: %@", mirrored ? @"SIM" : @"NÃO");
    
    // Atualiza o espelhamento no WebRTCManager
    if (_webRTCManager) {
        [_webRTCManager setVideoMirrored:mirrored];
    }
}

#pragma mark - Status Methods

- (NSDictionary *)getStatus {
    // Retorna informações de status atualizadas
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    
    [status setObject:@(_active) forKey:@"active"];
    [status setObject:@(_framesProcessed) forKey:@"framesProcessed"];
    [status setObject:@(_framesDropped) forKey:@"framesDropped"];
    
    // Taxa de frames calculada sobre os últimos segundos
    float fps = 0;
    if (_webRTCManager && _webRTCManager.frameConverter) {
        fps = _webRTCManager.frameConverter.currentFps;
    }
    [status setObject:@(fps) forKey:@"currentFps"];
    
    // Informações sobre o formato
    [status setObject:[NSString stringWithFormat:@"%dx%d", _currentDimensions.width, _currentDimensions.height] forKey:@"dimensions"];
    
    // Formato de pixel atual
    if (_webRTCManager && _webRTCManager.frameConverter) {
        IOSPixelFormat pixelFormat = _webRTCManager.frameConverter.detectedPixelFormat;
        [status setObject:[WebRTCFrameConverter stringFromPixelFormat:pixelFormat] forKey:@"pixelFormat"];
    }
    
    return status;
}

- (void)setActive:(BOOL)active {
    if (_active == active) {
        return;
    }
    
    if (active) {
        if (_webRTCManager) {
            _active = YES;
            writeLog(@"[WebRTCCameraAdapter] Ativado");
        } else {
            writeLog(@"[WebRTCCameraAdapter] Não é possível ativar sem um WebRTCManager");
        }
    } else {
        _active = NO;
        writeLog(@"[WebRTCCameraAdapter] Desativado");
    }
}

@end
