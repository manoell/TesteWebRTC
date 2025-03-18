#import "WebRTCBufferInjector.h"
#import "logger.h"
#import <objc/runtime.h>

// Chave associada para metadata dos buffers
static void *kBufferOriginKey = &kBufferOriginKey;

@implementation WebRTCBufferInjector

#pragma mark - Singleton Implementation

+ (instancetype)sharedInstance {
    static WebRTCBufferInjector *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _active = NO;
        _configured = NO;
        _originalDelegates = [NSMutableDictionary dictionary];
        _webRTCManager = [WebRTCManager sharedInstance];
        _frameConverter = [[WebRTCFrameConverter alloc] init];
        _currentCameraPosition = AVCaptureDevicePositionUnspecified;
        
        writeLog(@"[WebRTCBufferInjector] Inicializado");
    }
    return self;
}

#pragma mark - Configuration

- (void)configureWithSession:(AVCaptureSession *)session {
    if (self.configured) return;
    
    // Configurar o WebRTCManager se necessário
    if (!self.webRTCManager) {
        self.webRTCManager = [WebRTCManager sharedInstance];
    }
    
    // Configurar o FrameConverter
    [self.frameConverter reset];
    
    // Detectar posição da câmera atual
    for (AVCaptureDeviceInput *input in session.inputs) {
        if ([input.device hasMediaType:AVMediaTypeVideo]) {
            self.currentCameraPosition = input.device.position;
            break;
        }
    }
    
    // Adaptar o WebRTCManager para a câmera atual
    [self.webRTCManager adaptToNativeCameraWithPosition:self.currentCameraPosition];
    
    // Configurar o relógio de captura para sincronização
    if ([session respondsToSelector:@selector(masterClock)]) {
        CMClockRef sessionClock = [session masterClock];
        if (sessionClock) {
            [self.frameConverter setCaptureSessionClock:sessionClock];
            writeLog(@"[WebRTCBufferInjector] Configurado relógio de sessão para sincronização");
        }
    }
    
    self.configured = YES;
    writeLog(@"[WebRTCBufferInjector] Configurado com sucesso para sessão");
}

- (void)activateInjection {
    if (self.active) return;
    
    writeLog(@"[WebRTCBufferInjector] Ativando injeção de buffer");
    self.active = YES;
    
    // Iniciar a conexão WebRTC se necessário
    if (self.webRTCManager && self.webRTCManager.state != WebRTCManagerStateConnected) {
        [self.webRTCManager startWebRTC];
    }
}

- (void)deactivateInjection {
    if (!self.active) return;
    
    writeLog(@"[WebRTCBufferInjector] Desativando injeção de buffer");
    self.active = NO;
}

- (void)registerOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!delegate) return;
    
    // Armazenar o delegate original e sua queue para encaminhamento
    NSString *key = [NSString stringWithFormat:@"%p", delegate];
    self.originalDelegates[key] = @{
        @"delegate": delegate,
        @"queue": queue ?: dispatch_get_main_queue()
    };
    
    writeLog(@"[WebRTCBufferInjector] Delegate registrado: %@", delegate);
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

// Método principal que substitui os frames da câmera
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)originalBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificar se a substituição está ativa
    if (!self.isActive) {
        // Se não estiver ativa, passar o buffer original
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Extrair informações do buffer original para sincronização precisa
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
    if (!formatDescription) {
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Extrair dimensões e formato do buffer original
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    OSType pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription);
    writeVerboseLog(@"[WebRTCBufferInjector] Pixel format: %d", (int)pixelFormat);
    
    // Verificar orientação da conexão
    AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
    if ([connection isVideoOrientationSupported]) {
        orientation = connection.videoOrientation;
        [self.webRTCManager adaptOutputToVideoOrientation:(int)orientation];
    }
    
    // Adaptar o WebRTCManager para coincidir com a câmera nativa
    [self.webRTCManager setTargetResolution:dimensions];
    [self.webRTCManager adaptToNativeCameraWithPosition:self.currentCameraPosition];
    
    // Obter buffer WebRTC sincronizado e adaptado com metadados preservados
    CMSampleBufferRef webRTCBuffer = [self.webRTCManager getLatestVideoSampleBufferWithOriginalMetadata:originalBuffer];
    
    // Se não temos buffer WebRTC válido, usar o original
    if (!webRTCBuffer || !CMSampleBufferIsValid(webRTCBuffer)) {
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Preservar metadados críticos do buffer original
    if ([self.frameConverter respondsToSelector:@selector(applyMetadataToSampleBuffer:metadata:)]) {
        NSDictionary *metadata = [self.frameConverter extractMetadataFromSampleBuffer:originalBuffer];
        if (metadata) {
            [self.frameConverter applyMetadataToSampleBuffer:webRTCBuffer metadata:metadata];
        }
    }
    
    // Entregar o buffer substituído aos delegates
    [self forwardBuffer:webRTCBuffer toOutput:output connection:connection];
    
    // Liberar buffer WebRTC após uso
    CFRelease(webRTCBuffer);
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Encaminhar evento de buffer descartado para todos os delegates
    for (NSString *key in self.originalDelegates) {
        NSDictionary *delegateInfo = self.originalDelegates[key];
        id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = delegateInfo[@"delegate"];
        dispatch_queue_t queue = delegateInfo[@"queue"];
        
        if (delegate && [delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
            dispatch_async(queue, ^{
                @try {
                    [delegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCBufferInjector] Erro ao encaminhar evento de buffer descartado: %@", exception);
                }
            });
        }
    }
}

- (void)forwardBuffer:(CMSampleBufferRef)buffer toOutput:(AVCaptureOutput *)output connection:(AVCaptureConnection *)connection {
    // Encaminhar o buffer para todos os delegates registrados
    for (NSString *key in self.originalDelegates) {
        NSDictionary *delegateInfo = self.originalDelegates[key];
        id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = delegateInfo[@"delegate"];
        dispatch_queue_t queue = delegateInfo[@"queue"];
        
        if (delegate && [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            dispatch_async(queue, ^{
                @try {
                    [delegate captureOutput:output didOutputSampleBuffer:buffer fromConnection:connection];
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCBufferInjector] Erro ao encaminhar buffer: %@", exception);
                }
            });
        }
    }
}

- (void)forwardOriginalBuffer:(CMSampleBufferRef)buffer toOutput:(AVCaptureOutput *)output connection:(AVCaptureConnection *)connection {
    // Encaminhar o buffer original sem modificações
    [self forwardBuffer:buffer toOutput:output connection:connection];
}

@end
