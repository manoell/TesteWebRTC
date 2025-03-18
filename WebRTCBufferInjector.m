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
    if (self.webRTCManager && !self.webRTCManager.frameConverter.isReceivingFrames) {
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

// No WebRTCBufferInjector.m
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)originalBuffer fromConnection:(AVCaptureConnection *)connection {
    static int frameCount = 0;
    frameCount++;
    
    BOOL isLogFrame = (frameCount % 60 == 0 || frameCount < 10);  // Log primeiros 10 frames e depois a cada 60
    NSString *motivo = nil;
    
    if (isLogFrame) {
        writeLog(@"[WebRTCBufferInjector] Processando frame #%d, substituição ativa: %@",
                frameCount, self.active ? @"SIM" : @"NÃO");
    }
    
    @try {
        // 1. Verificar state inicial
        if (!self.active) {
            motivo = @"Substituição inativa";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        // 2. Verificar manager WebRTC
        if (!self.webRTCManager) {
            motivo = @"WebRTCManager não está disponível";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        // 3. Verificar buffer original
        if (!originalBuffer || !CMSampleBufferIsValid(originalBuffer)) {
            motivo = @"Buffer original inválido";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        // 4. Verificar se WebRTC está recebendo frames
        if (!self.webRTCManager.frameConverter || !self.webRTCManager.frameConverter.isReceivingFrames) {
            motivo = @"WebRTC não está recebendo frames";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        // 5. Extrair informações do buffer original para debug e adaptação
        CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
        if (!formatDescription) {
            motivo = @"Format description não disponível";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        // 6. Extrair dimensões e formato do buffer original
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        OSType pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription);
        
        if (isLogFrame) {
            writeLog(@"[WebRTCBufferInjector] Frame original #%d - Dimensões: %dx%d, Formato: %d",
                    frameCount, dimensions.width, dimensions.height, (int)pixelFormat);
        }
        
        // 7. Verificar orientação da conexão
        if ([connection respondsToSelector:@selector(isVideoOrientationSupported)] &&
            [connection isVideoOrientationSupported]) {
            AVCaptureVideoOrientation orientation = connection.videoOrientation;
            [self.webRTCManager adaptOutputToVideoOrientation:(int)orientation];
        }
        
        // 8. Adaptar o WebRTCManager para coincidir com a câmera nativa
        [self.webRTCManager setTargetResolution:dimensions];
        
        // 9. Obter buffer WebRTC sincronizado e adaptado
        if (isLogFrame) writeLog(@"[WebRTCBufferInjector] Solicitando buffer WebRTC...");
        
        CMSampleBufferRef webRTCBuffer = [self.webRTCManager getLatestVideoSampleBufferWithOriginalMetadata:originalBuffer];
        
        // 10. Se não temos buffer WebRTC válido, usar o original
        if (!webRTCBuffer) {
            motivo = @"WebRTC buffer não disponível";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        if (!CMSampleBufferIsValid(webRTCBuffer)) {
            motivo = @"WebRTC buffer inválido";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            if (webRTCBuffer) CFRelease(webRTCBuffer);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        // 11. Verificar se os formatos são compatíveis
        if (isLogFrame) {
            CMFormatDescriptionRef webRTCDescription = CMSampleBufferGetFormatDescription(webRTCBuffer);
            if (webRTCDescription) {
                CMVideoDimensions webRTCDims = CMVideoFormatDescriptionGetDimensions(webRTCDescription);
                OSType webRTCFormat = CMFormatDescriptionGetMediaSubType(webRTCDescription);
                
                writeLog(@"[WebRTCBufferInjector] Buffer WebRTC: %dx%d, formato: %d",
                        webRTCDims.width, webRTCDims.height, (int)webRTCFormat);
            }
        }
        
        if (![self isBufferCompatible:webRTCBuffer withOriginal:originalBuffer]) {
            motivo = @"Formatos incompatíveis";
            if (isLogFrame) writeLog(@"[WebRTCBufferInjector] %@", motivo);
            CFRelease(webRTCBuffer);
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
            return;
        }
        
        // 12. Substituição bem-sucedida - encaminhar buffer WebRTC
        if (isLogFrame) {
            writeLog(@"[WebRTCBufferInjector] Substituindo frame #%d com sucesso", frameCount);
        }
        
        // 13. Encaminhar o buffer WebRTC para os delegates registrados
        @try {
            [self forwardBuffer:webRTCBuffer toOutput:output connection:connection];
        } @catch (NSException *exception) {
            writeErrorLog(@"[WebRTCBufferInjector] Exceção ao encaminhar buffer substituído: %@", exception);
            // Em caso de erro ao encaminhar, tentar encaminhar o original
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        }
        
        // 14. Liberar o buffer WebRTC
        CFRelease(webRTCBuffer);
        
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCBufferInjector] Exceção ao processar frame: %@", exception);
        
        // Em caso de erro, garantir que o buffer original seja encaminhado
        @try {
            [self forwardOriginalBuffer:originalBuffer toOutput:output connection:connection];
        } @catch (NSException *innerException) {
            writeErrorLog(@"[WebRTCBufferInjector] Exceção adicional ao tentar encaminhar buffer original: %@", innerException);
        }
    }
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
                    kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                    kCMSampleBufferAttachmentKey_DroppedFrameReason,
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

// Método melhorado para verificar compatibilidade de buffers com logs detalhados
- (BOOL)isBufferCompatible:(CMSampleBufferRef)webRTCBuffer withOriginal:(CMSampleBufferRef)originalBuffer {
    if (!webRTCBuffer || !originalBuffer) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Um ou ambos os buffers são NULL");
        return NO;
    }
    
    // Verificar validade dos buffers
    if (!CMSampleBufferIsValid(webRTCBuffer) || !CMSampleBufferIsValid(originalBuffer)) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Um ou ambos os buffers são inválidos");
        return NO;
    }
    
    // Obter descrições de formato com verificações de segurança
    CMFormatDescriptionRef originalFormat = CMSampleBufferGetFormatDescription(originalBuffer);
    CMFormatDescriptionRef webRTCFormat = CMSampleBufferGetFormatDescription(webRTCBuffer);
    
    if (!originalFormat || !webRTCFormat) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Descrição de formato não disponível");
        return NO;
    }
    
    // Verificar tipo de mídia (deve ser vídeo para ambos)
    CMMediaType originalMediaType = CMFormatDescriptionGetMediaType(originalFormat);
    CMMediaType webRTCMediaType = CMFormatDescriptionGetMediaType(webRTCFormat);
    
    if (originalMediaType != webRTCMediaType || originalMediaType != kCMMediaType_Video) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Tipos de mídia incompatíveis: original=%d, webRTC=%d",
                     (int)originalMediaType, (int)webRTCMediaType);
        return NO;
    }
    
    // Obter dimensões dos buffers
    CMVideoDimensions originalDims = CMVideoFormatDescriptionGetDimensions(originalFormat);
    CMVideoDimensions webRTCDims = CMVideoFormatDescriptionGetDimensions(webRTCFormat);
    
    // Obter formatos de pixel
    OSType originalPixelFormat = CMFormatDescriptionGetMediaSubType(originalFormat);
    OSType webRTCPixelFormat = CMFormatDescriptionGetMediaSubType(webRTCFormat);
    
    // Log detalhado para diagnóstico ocasional (não em cada frame)
    static int logCounter = 0;
    if (++logCounter % 100 == 0) {
        writeLog(@"[WebRTCBufferInjector] Verificando compatibilidade - Original: %dx%d (%d), WebRTC: %dx%d (%d)",
               originalDims.width, originalDims.height, (int)originalPixelFormat,
               webRTCDims.width, webRTCDims.height, (int)webRTCPixelFormat);
    }
    
    // Permitir tolerância de 10% nas dimensões
    float widthRatio = (float)webRTCDims.width / originalDims.width;
    float heightRatio = (float)webRTCDims.height / originalDims.height;
    
    if (widthRatio < 0.9 || widthRatio > 1.1 || heightRatio < 0.9 || heightRatio > 1.1) {
        // Log apenas ocasionalmente para evitar spam
        if (logCounter % 100 == 0) {
            writeLog(@"[WebRTCBufferInjector] Dimensões incompatíveis - Original: %dx%d, WebRTC: %dx%d",
                   originalDims.width, originalDims.height, webRTCDims.width, webRTCDims.height);
        }
        return NO;
    }
    
    // Verificar formatos de pixel - comentado para maior flexibilidade
    // Se descomentar isso, será mais estrito na compatibilidade de formatos
    /*
    if (originalPixelFormat != webRTCPixelFormat) {
        // Permitir algumas substituições comuns entre formatos compatíveis
        BOOL isCompatibleFormat =
            // Permitir substituição entre formatos YUV
            ((originalPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              originalPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) &&
             (webRTCPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              webRTCPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) ||
            // Permitir substituição entre formatos RGBA/BGRA
            ((originalPixelFormat == kCVPixelFormatType_32BGRA ||
              originalPixelFormat == kCVPixelFormatType_32RGBA) &&
             (webRTCPixelFormat == kCVPixelFormatType_32BGRA ||
              webRTCPixelFormat == kCVPixelFormatType_32RGBA));
        
        if (!isCompatibleFormat) {
            if (logCounter % 100 == 0) {
                writeLog(@"[WebRTCBufferInjector] Formatos de pixel incompatíveis - Original: %d, WebRTC: %d",
                        (int)originalPixelFormat, (int)webRTCPixelFormat);
            }
            return NO;
        }
    }
    */
    
    // Verificar timing info (opcional)
    /*
    CMSampleTimingInfo originalTiming;
    CMSampleTimingInfo webRTCTiming;
    
    if (CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &originalTiming) == noErr &&
        CMSampleBufferGetSampleTimingInfo(webRTCBuffer, 0, &webRTCTiming) == noErr) {
        
        // Verificar duração dos frames (tolerância de 20%)
        float durationRatio = CMTimeGetSeconds(webRTCTiming.duration) / CMTimeGetSeconds(originalTiming.duration);
        if (durationRatio < 0.8 || durationRatio > 1.2) {
            if (logCounter % 100 == 0) {
                writeLog(@"[WebRTCBufferInjector] Durações de frame incompatíveis - Original: %.3fs, WebRTC: %.3fs",
                        CMTimeGetSeconds(originalTiming.duration), CMTimeGetSeconds(webRTCTiming.duration));
            }
            // Comentado para não falhar por timing
            // return NO;
        }
    }
    */
    
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
