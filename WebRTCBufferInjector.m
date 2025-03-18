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
    if (_active) return; // Usar a variável de instância diretamente
    
    writeLog(@"[WebRTCBufferInjector] Ativando injeção de buffer");
    _active = YES; // Modificar a variável de instância diretamente
    
    // Iniciar a conexão WebRTC se necessário
    if (self.webRTCManager && self.webRTCManager.state != WebRTCManagerStateConnected) {
        [self.webRTCManager startWebRTC];
    }
}

- (void)deactivateInjection {
    if (!_active) return; // Usar a variável de instância diretamente
    
    writeLog(@"[WebRTCBufferInjector] Desativando injeção de buffer");
    _active = NO; // Modificar a variável de instância diretamente
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
    if (!self.isActive || !self.webRTCManager || !originalBuffer || !CMSampleBufferIsValid(originalBuffer)) {
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Debug do pixel format
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
    if (formatDescription) {
        OSType pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription);
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        
        // Adicionar um log mais detalhado
        writeLog(@"[WebRTCBufferInjector] Frame original: formato=%d, dimensões=%dx%d",
               (int)pixelFormat, dimensions.width, dimensions.height);
    }
    
    // Obter buffer WebRTC com o formato adequado
    CMSampleBufferRef webRTCBuffer = [self.webRTCManager getLatestVideoSampleBufferWithOriginalMetadata:originalBuffer];
    
    // Verificar se o buffer WebRTC é válido
    if (!webRTCBuffer || !CMSampleBufferIsValid(webRTCBuffer)) {
        writeLog(@"[WebRTCBufferInjector] Usando buffer original - WebRTC buffer não disponível");
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Encaminhar o buffer WebRTC
    writeLog(@"[WebRTCBufferInjector] Substituindo frame da câmera com frame WebRTC");
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
    // Encaminhar o buffer original sem modificações
    [self forwardBuffer:buffer toOutput:output connection:connection];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    
    if (active) {
        [self activateInjection]; // Não há mais chamada recursiva aqui
    } else {
        [self deactivateInjection]; // Não há mais chamada recursiva aqui
    }
}

@end
