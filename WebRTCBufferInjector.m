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
    if (self.webRTCManager && ![self.webRTCManager isReceivingFrames]) {
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

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)originalBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificar se a substituição está ativa
    if (!self.active || !self.webRTCManager || !originalBuffer || !CMSampleBufferIsValid(originalBuffer)) {
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Extrair informações do buffer original para debug e adaptação
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
    if (!formatDescription) {
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Extrair dimensões e formato do buffer original
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    OSType pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription);
    
    // Verificar orientação da conexão
    AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
    if ([connection isVideoOrientationSupported]) {
        orientation = connection.videoOrientation;
        [self.webRTCManager adaptOutputToVideoOrientation:(int)orientation];
    }
    
    // Extrair metadados do buffer original para preservar em buffer WebRTC
    NSDictionary *originalMetadata = [self.frameConverter extractMetadataFromSampleBuffer:originalBuffer];
    
    // Log limitado para não afetar performance
    static int frameCount = 0;
    BOOL shouldLog = (++frameCount % 300 == 0);
    
    if (shouldLog) {
        writeLog(@"[WebRTCBufferInjector] Frame #%d - Dimensões: %dx%d, Formato: %d",
               frameCount, dimensions.width, dimensions.height, (int)pixelFormat);
    }
    
    // Adaptar o WebRTCManager para coincidir com a câmera nativa
    [self.webRTCManager setTargetResolution:dimensions];
    [self.webRTCManager adaptToNativeCameraWithPosition:self.currentCameraPosition];
    
    // Obter buffer WebRTC sincronizado e adaptado
    CMSampleBufferRef webRTCBuffer = [self.webRTCManager getLatestVideoSampleBufferWithOriginalMetadata:originalBuffer];
    
    // Se não temos buffer WebRTC válido, usar o original
    if (!webRTCBuffer || !CMSampleBufferIsValid(webRTCBuffer)) {
        if (shouldLog) {
            writeLog(@"[WebRTCBufferInjector] Usando buffer original - WebRTC buffer não disponível");
        }
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Marcar o buffer como substituído (metadata para debug)
    objc_setAssociatedObject((__bridge id)webRTCBuffer, kBufferOriginKey, @"webrtc", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Aplicar metadados originais ao buffer WebRTC para preservar informações da câmera
    if (originalMetadata) {
        [self.frameConverter applyMetadataToSampleBuffer:webRTCBuffer metadata:originalMetadata];
    }
    
    // Encaminhar o buffer WebRTC para os delegates registrados
    [self forwardBuffer:webRTCBuffer toOutput:output connection:connection];
    
    // Liberar o buffer WebRTC
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
    // Encaminhar o buffer original (sem substituição) para todos os delegates
    [self forwardBuffer:buffer toOutput:output connection:connection];
}

@end
