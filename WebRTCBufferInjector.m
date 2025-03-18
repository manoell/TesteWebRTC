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
        _frameCount = 0;
        _replacedFrameCount = 0;
        
        writeLog(@"[WebRTCBufferInjector] Inicializado");
    }
    return self;
}

#pragma mark - Configuration

- (void)configureWithSession:(AVCaptureSession *)session {
    if (self.configured && self.captureSession == session) {
        writeLog(@"[WebRTCBufferInjector] Já configurado para esta sessão, ignorando chamada duplicada");
        return;
    }
    
    // Armazenar referência à sessão
    self.captureSession = session;
    
    // Configurar o WebRTCManager se necessário
    if (!self.webRTCManager) {
        self.webRTCManager = [WebRTCManager sharedInstance];
    }
    
    // Configurar o FrameConverter
    [self.frameConverter reset];
    
    // Atualizar informações da câmera
    [self updateCameraInfo:session];
    
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

- (void)updateCameraInfo:(AVCaptureSession *)session {
    // Detectar posição da câmera atual
    AVCaptureDevicePosition oldPosition = self.currentCameraPosition;
    
    for (AVCaptureDeviceInput *input in session.inputs) {
        if ([input.device hasMediaType:AVMediaTypeVideo]) {
            self.currentCameraPosition = input.device.position;
            
            // Log detalhado sobre o dispositivo de câmera
            writeLog(@"[WebRTCBufferInjector] Câmera detectada: %@ (posição: %@, ID: %@)",
                   input.device.localizedName,
                   self.currentCameraPosition == AVCaptureDevicePositionBack ? @"traseira" :
                   (self.currentCameraPosition == AVCaptureDevicePositionFront ? @"frontal" : @"desconhecida"),
                   input.device.uniqueID);
            
            // Se a sessão estiver configurada para formato específico, tentar detectá-lo
            if ([input.device respondsToSelector:@selector(activeFormat)]) {
                AVCaptureDeviceFormat *format = input.device.activeFormat;
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                
                writeLog(@"[WebRTCBufferInjector] Formato ativo: %dx%d, %@ fps",
                       dimensions.width, dimensions.height,
                       format.videoSupportedFrameRateRanges.firstObject.maxFrameRate);
            }
            
            break;
        }
    }
    
    // Se a posição mudou, atualizar o WebRTCManager
    if (oldPosition != self.currentCameraPosition) {
        [self.webRTCManager adaptToNativeCameraWithPosition:self.currentCameraPosition];
    }
}

- (void)activateInjection {
    if (_active) {
        writeLog(@"[WebRTCBufferInjector] Injeção já está ativa, ignorando chamada duplicada");
        return;
    }
    
    writeLog(@"[WebRTCBufferInjector] Ativando injeção de buffer");
    _active = YES;
    
    // Verificar se estamos recebendo frames antes de prosseguir
    if (self.webRTCManager && !self.webRTCManager.isReceivingFrames) {
        // Iniciar a conexão WebRTC se necessário
        [self.webRTCManager startWebRTC];
        
        // Aguardar um pouco para dar tempo de inicializar a conexão WebRTC
        // Este delay ajuda a garantir que os frames já estejam disponíveis
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            [self activateInjectionForOutputs];
        });
    } else {
        // WebRTC já está recebendo frames, ativar injeção imediatamente
        [self activateInjectionForOutputs];
    }
}

- (void)activateInjectionForOutputs {
    // Só prosseguir se ainda estiver ativo (pode ter sido desativado enquanto esperávamos)
    if (!_active) return;
    
    // Procurar todas as saídas de vídeo para substituir delegates
    if (self.captureSession) {
        BOOL delegateFound = NO;
        
        for (AVCaptureOutput *output in self.captureSession.outputs) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                AVCaptureVideoDataOutput *videoOutput = (AVCaptureVideoDataOutput *)output;
                
                // Armazenar delegate original para referência, se ainda não tiver sido armazenado
                id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate = videoOutput.sampleBufferDelegate;
                dispatch_queue_t originalQueue = videoOutput.sampleBufferCallbackQueue;
                
                if (originalDelegate && originalDelegate != self) {
                    [self registerOriginalDelegate:originalDelegate queue:originalQueue];
                    
                    // Substituir o delegate pelo injector
                    [videoOutput setSampleBufferDelegate:self queue:originalQueue];
                    
                    writeLog(@"[WebRTCBufferInjector] Delegate substituído para saída de vídeo");
                    delegateFound = YES;
                }
            }
        }
        
        if (!delegateFound) {
            writeWarningLog(@"[WebRTCBufferInjector] Nenhum delegate de saída de vídeo encontrado para substituir");
        }
    }
}

- (void)deactivateInjection {
    if (!_active) {
        writeLog(@"[WebRTCBufferInjector] Injeção já está inativa, ignorando chamada");
        return;
    }
    
    writeLog(@"[WebRTCBufferInjector] Desativando injeção de buffer");
    _active = NO;
    
    // Restaurar delegates originais
    if (self.captureSession) {
        for (AVCaptureOutput *output in self.captureSession.outputs) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                AVCaptureVideoDataOutput *videoOutput = (AVCaptureVideoDataOutput *)output;
                
                // Se estamos atualmente definidos como delegate, restaurar o delegate original
                if (videoOutput.sampleBufferDelegate == self) {
                    // Encontrar o delegate original para esta saída (pode haver múltiplos)
                    // Como simplesmente não temos mapeamento direto, restauramos o primeiro delegate compatível
                    for (NSString *key in self.originalDelegates) {
                        NSDictionary *delegateInfo = self.originalDelegates[key];
                        id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = delegateInfo[@"delegate"];
                        dispatch_queue_t queue = delegateInfo[@"queue"];
                        
                        if (delegate) {
                            [videoOutput setSampleBufferDelegate:delegate queue:queue];
                            writeLog(@"[WebRTCBufferInjector] Delegate original restaurado para saída de vídeo");
                            break;
                        }
                    }
                }
            }
        }
    }
}

- (void)registerOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!delegate) {
        writeLog(@"[WebRTCBufferInjector] Tentativa de registrar delegate nulo");
        return;
    }
    
    // Armazenar o delegate original e sua queue para encaminhamento
    NSString *key = [NSString stringWithFormat:@"%p", delegate];
    
    // Verificar se este delegate já está registrado
    if (self.originalDelegates[key]) {
        writeLog(@"[WebRTCBufferInjector] Delegate %@ já registrado, atualizando queue",
               NSStringFromClass([delegate class]));
    }
    
    self.originalDelegates[key] = @{
        @"delegate": delegate,
        @"queue": queue ?: dispatch_get_main_queue()
    };
    
    writeLog(@"[WebRTCBufferInjector] Delegate registrado: %@ com key %@",
           NSStringFromClass([delegate class]), key);
    
    // Verificar se o delegate implementa os métodos necessários
    BOOL hasOutputMethod = [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)];
    BOOL hasDropMethod = [delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)];
    
    writeLog(@"[WebRTCBufferInjector] Delegate implementa didOutputSampleBuffer: %@, didDropSampleBuffer: %@",
           hasOutputMethod ? @"Sim" : @"Não",
           hasDropMethod ? @"Sim" : @"Não");
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)originalBuffer fromConnection:(AVCaptureConnection *)connection {
    // Incrementar contador de frames
    self.frameCount++;
    BOOL logFrame = (self.frameCount % 300 == 0); // Log a cada 300 frames
    
    // Verificar se a substituição está ativa
    if (!self.active || !self.webRTCManager || !originalBuffer || !CMSampleBufferIsValid(originalBuffer)) {
        if (logFrame) {
            writeLog(@"[WebRTCBufferInjector] Usando buffer original - Substituição inativa ou buffer inválido");
        }
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Verificar se WebRTC está recebendo frames
    if (!self.webRTCManager.isReceivingFrames) {
        if (logFrame) {
            writeLog(@"[WebRTCBufferInjector] Usando buffer original - WebRTC não está recebendo frames");
        }
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Debug do pixel format
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
    if (formatDescription && logFrame) {
        OSType pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription);
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        
        writeLog(@"[WebRTCBufferInjector] Frame original #%lu: formato=%d, dimensões=%dx%d",
               (unsigned long)self.frameCount, (int)pixelFormat, dimensions.width, dimensions.height);
    }
    
    // Verificar orientação da conexão
    if ([connection isVideoOrientationSupported]) {
        AVCaptureVideoOrientation orientation = connection.videoOrientation;
        [self.webRTCManager adaptOutputToVideoOrientation:(int)orientation];
    }
    
    // Verificar espelhamento
    if ([connection isVideoMirroredSupported]) {
        BOOL mirrored = connection.videoMirrored;
        [self.webRTCManager setVideoMirrored:mirrored];
    }
    
    // Se o formato da câmera mudou, atualizar o WebRTCManager
    if (formatDescription) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        [self.webRTCManager setTargetResolution:dimensions];
    }
    
    // Obter buffer WebRTC com timing e metadados sincronizados
    CMSampleBufferRef webRTCBuffer = [self.webRTCManager getLatestVideoSampleBufferWithOriginalMetadata:originalBuffer];
    
    // Verificar se o buffer WebRTC é válido
    if (!webRTCBuffer || !CMSampleBufferIsValid(webRTCBuffer)) {
        if (logFrame) {
            writeLog(@"[WebRTCBufferInjector] Usando buffer original - WebRTC buffer não disponível");
        }
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        return;
    }
    
    // Verificar se os formatos são compatíveis
    if (![self isBufferCompatible:webRTCBuffer withOriginal:originalBuffer]) {
        if (logFrame) {
            writeLog(@"[WebRTCBufferInjector] Usando buffer original - Formatos incompatíveis");
        }
        [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        CFRelease(webRTCBuffer);
        return;
    }
    
    // Aplicar metadados do buffer original (exposição, balance de branco, etc.)
    BOOL metadataApplied = [self applyMetadataFromBuffer:originalBuffer toBuffer:webRTCBuffer];
    if (!metadataApplied && logFrame) {
        writeLog(@"[WebRTCBufferInjector] Aviso: Não foi possível aplicar todos os metadados");
    }
    
    if (logFrame) {
        writeLog(@"[WebRTCBufferInjector] Substituindo frame da câmera com frame WebRTC");
        
        // Verificar informações do buffer WebRTC
        CMFormatDescriptionRef webRTCFormatDesc = CMSampleBufferGetFormatDescription(webRTCBuffer);
        if (webRTCFormatDesc) {
            OSType webRTCPixelFormat = CMFormatDescriptionGetMediaSubType(webRTCFormatDesc);
            CMVideoDimensions webRTCDims = CMVideoFormatDescriptionGetDimensions(webRTCFormatDesc);
            writeLog(@"[WebRTCBufferInjector] Frame WebRTC: formato=%d, dimensões=%dx%d",
                   (int)webRTCPixelFormat, webRTCDims.width, webRTCDims.height);
        }
    }
    
    // Incrementar contador de frames substituídos
    self.replacedFrameCount++;
    
    // Encaminhar o buffer WebRTC para os delegates registrados
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
    if (!buffer || self.originalDelegates.count == 0) {
        return;
    }
    
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

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    
    if (active) {
        [self activateInjection];
    } else {
        [self deactivateInjection];
    }
}

#pragma mark - Helper Methods

- (BOOL)applyMetadataFromBuffer:(CMSampleBufferRef)originalBuffer toBuffer:(CMSampleBufferRef)webRTCBuffer {
    if (!originalBuffer || !webRTCBuffer) return NO;
    
    BOOL success = YES;
    
    @try {
        // 1. Copiar attachments do buffer original
        CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(originalBuffer, false);
        if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
            CFDictionaryRef originalAttachments = (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
            
            // Obter attachments do buffer WebRTC
            CFArrayRef webRTCAttachmentsArray = CMSampleBufferGetSampleAttachmentsArray(webRTCBuffer, true);
            if (webRTCAttachmentsArray && CFArrayGetCount(webRTCAttachmentsArray) > 0) {
                CFMutableDictionaryRef webRTCAttachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(webRTCAttachmentsArray, 0);
                
                // Copiar chaves específicas
                const void *keys[] = {
                    kCMSampleAttachmentKey_DisplayImmediately,
                    kCMSampleAttachmentKey_ResetDecoderBeforeDecoding,
                    kCMSampleAttachmentKey_DroppedFrameReason,
                    kCMSampleAttachmentKey_NotSync
                };
                
                for (int i = 0; i < 4; i++) {
                    const void *value = CFDictionaryGetValue(originalAttachments, keys[i]);
                    if (value) {
                        CFDictionarySetValue(webRTCAttachments, keys[i], value);
                    }
                }
            }
        }
        
        // 2. Copiar metadados específicos da câmera (como informações de exposição)
        CFDictionaryRef originalMetadata = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                       originalBuffer,
                                                                       kCMAttachmentMode_ShouldPropagate);
        if (originalMetadata) {
            // Anexar metadados ao buffer WebRTC
            CMSetAttachments(webRTCBuffer, originalMetadata, kCMAttachmentMode_ShouldPropagate);
            CFRelease(originalMetadata);
        }
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCBufferInjector] Erro ao aplicar metadados: %@", exception);
        success = NO;
    }
    
    return success;
}

- (BOOL)isBufferCompatible:(CMSampleBufferRef)webRTCBuffer withOriginal:(CMSampleBufferRef)originalBuffer {
    if (!webRTCBuffer || !originalBuffer) return NO;
    
    // Verificar formatos
    CMFormatDescriptionRef originalFormat = CMSampleBufferGetFormatDescription(originalBuffer);
    CMFormatDescriptionRef webRTCFormat = CMSampleBufferGetFormatDescription(webRTCBuffer);
    
    if (!originalFormat || !webRTCFormat) return NO;
    
    // Verificar tipo de mídia (deve ser vídeo para ambos)
    CMMediaType originalMediaType = CMFormatDescriptionGetMediaType(originalFormat);
    CMMediaType webRTCMediaType = CMFormatDescriptionGetMediaType(webRTCFormat);
    
    if (originalMediaType != webRTCMediaType || originalMediaType != kCMMediaType_Video) {
        return NO;
    }
    
    // Verificar dimensões - devem ser suficientemente próximas
    CMVideoDimensions originalDims = CMVideoFormatDescriptionGetDimensions(originalFormat);
    CMVideoDimensions webRTCDims = CMVideoFormatDescriptionGetDimensions(webRTCFormat);
    
    // Permitir tolerância de 10% nas dimensões
    float widthRatio = (float)webRTCDims.width / originalDims.width;
    float heightRatio = (float)webRTCDims.height / originalDims.height;
    
    if (widthRatio < 0.9 || widthRatio > 1.1 || heightRatio < 0.9 || heightRatio > 1.1) {
        // Log apenas ocasionalmente para evitar spam
        if (self.frameCount % 300 == 0) {
            writeLog(@"[WebRTCBufferInjector] Dimensões incompatíveis - Original: %dx%d, WebRTC: %dx%d",
                   originalDims.width, originalDims.height, webRTCDims.width, webRTCDims.height);
        }
        return NO;
    }
    
    return YES;
}

- (NSDictionary *)getInjectionStats {
    return @{
        @"framesProcessed": @(self.frameCount),
        @"framesReplaced": @(self.replacedFrameCount),
        @"replacementRate": self.frameCount > 0 ? @((float)self.replacedFrameCount / self.frameCount) : @(0),
        @"isActive": @(self.active),
        @"isConfigured": @(self.configured),
        @"delegatesRegistered": @(self.originalDelegates.count),
        @"cameraPosition": @(self.currentCameraPosition)
    };
}

@end
