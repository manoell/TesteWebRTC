#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "WebRTCFrameConverter.h"
#import "logger.h"

// Definição para notificação customizada de mudança de câmera
static NSString *const AVCaptureDevicePositionDidChangeNotification = @"AVCaptureDevicePositionDidChangeNotification";

// Definições para alta qualidade de vídeo
#define kPreferredMaxWidth 3840  // 4K
#define kPreferredMaxHeight 2160 // 4K
#define kPreferredMaxFPS 60

// Tempos de espera (em segundos)
#define kConnectionTimeout 10.0      // Timeout para estabelecer conexão WebRTC
#define kPeerConnectionTimeout 8.0   // Timeout para estabelecer conexão peer
#define kReconnectInterval 1.5       // Intervalo entre tentativas de reconexão
#define kStatsCollectionInterval 2.0 // Intervalo para coleta de estatísticas
#define kStatusCheckInterval 1.0     // Intervalo para verificação de status
#define kFrameMonitoringInterval 1.0 // Intervalo para monitoramento de frames

// Número máximo de tentativas de reconexão (0 = infinito)
#define kMaxReconnectAttempts 5

@interface WebRTCManager ()
@property (nonatomic, assign) WebRTCManagerState state;
@property (nonatomic, assign) BOOL isReceivingFrames;
@property (nonatomic, assign) int reconnectAttempts;
@property (nonatomic, strong) dispatch_source_t reconnectTimer;
@property (nonatomic, strong) dispatch_source_t statsTimer;
@property (nonatomic, strong) dispatch_source_t statusCheckTimer;
@property (nonatomic, strong) dispatch_source_t frameCheckTimer;
@property (nonatomic, strong) dispatch_source_t connectionTimeoutTimer;
@property (nonatomic, assign) CFTimeInterval connectionStartTime;
@property (nonatomic, assign) BOOL hasReceivedFirstFrame;
@property (nonatomic, strong) NSMutableDictionary *sdpMediaConstraints;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign) BOOL autoAdaptToCameraResolution;
@property (nonatomic, assign) CMVideoDimensions targetResolution;
@property (nonatomic, assign) float targetFrameRate;
@property (nonatomic, strong) NSMutableArray *iceServers;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, assign) NSTimeInterval lastFrameReceivedTime;
@property (nonatomic, assign) BOOL usingBackCamera;
@property (nonatomic, assign) BOOL hasLocalStream;
@property (nonatomic, assign) int consecutiveReconnectFailures;
@property (nonatomic, strong) RTCAudioTrack *defaultAudioTrack;
@property (nonatomic, strong) RTCVideoTrack *defaultVideoTrack;
@property (nonatomic, assign) BOOL isSpeakerEnabled;

// Timer management
@property (nonatomic, strong) NSMutableDictionary *activeTimers;
@end

@implementation WebRTCManager

@synthesize state = _state;
@synthesize isReceivingFrames = _isReceivingFrames;

#pragma mark - Initialization & Lifecycle

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        _floatingWindow = window;
        _state = WebRTCManagerStateDisconnected;
        _isReceivingFrames = NO;
        _reconnectAttempts = 0;
        _hasReceivedFirstFrame = NO;
        _userRequestedDisconnect = NO;
        _usingBackCamera = NO;
        _hasLocalStream = NO;
        _consecutiveReconnectFailures = 0;
        _serverIP = @"192.168.0.178"; // Default IP - deve ser personalizado pelo usuário
        _activeTimers = [NSMutableDictionary dictionary];
        _isSpeakerEnabled = YES;
        
        // Inicializar o conversor de frame
        _frameConverter = [[WebRTCFrameConverter alloc] init];
        
        // Inicializar constraints para mídia de alta qualidade
        _sdpMediaConstraints = [NSMutableDictionary dictionaryWithDictionary:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        }];
        
        // Inicializar ice servers
        _iceServers = [NSMutableArray arrayWithObject:[self defaultSTUNServer]];
        
        // Target resolution e frame rate
        _targetResolution.width = kPreferredMaxWidth;
        _targetResolution.height = kPreferredMaxHeight;
        _targetFrameRate = kPreferredMaxFPS;
        
        // Notificações de orientação
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:@"UIDeviceOrientationDidChangeNotification"
                                                   object:nil];
        
        // Notificações de mudança de câmera
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cameraDidChange:)
                                                     name:AVCaptureDevicePositionDidChangeNotification
                                                   object:nil];
        
        // Log inicialização
        writeLog(@"[WebRTCManager] WebRTCManager inicializado com configurações para alta qualidade 4K/60fps");
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopAllTimers];
    [self stopWebRTC:YES];
}

#pragma mark - State Management

- (void)setState:(WebRTCManagerState)state {
    if (_state == state) {
        return;
    }
    
    WebRTCManagerState oldState = _state;
    _state = state;
    
    // Log da transição
    writeLog(@"[WebRTCManager] Estado alterado: %@ -> %@",
             [self stateToString:oldState],
             [self stateToString:state]);
    
    // Notificar FloatingWindow
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:[self statusMessageForState:state]];
    });
}

- (NSString *)stateToString:(WebRTCManagerState)state {
    switch (state) {
        case WebRTCManagerStateDisconnected: return @"Desconectado";
        case WebRTCManagerStateConnecting: return @"Conectando";
        case WebRTCManagerStateConnected: return @"Conectado";
        case WebRTCManagerStateError: return @"Erro";
        case WebRTCManagerStateReconnecting: return @"Reconectando";
        default: return @"Desconhecido";
    }
}

- (NSString *)statusMessageForState:(WebRTCManagerState)state {
    switch (state) {
        case WebRTCManagerStateDisconnected:
            return @"Desconectado";
        case WebRTCManagerStateConnecting:
            return @"Conectando ao servidor...";
        case WebRTCManagerStateConnected:
            return self.isReceivingFrames ? @"Conectado - Recebendo stream" : @"Conectado - Aguardando stream";
        case WebRTCManagerStateError:
            return @"Erro de conexão";
        case WebRTCManagerStateReconnecting:
            return [NSString stringWithFormat:@"Reconectando (%d)...", self.reconnectAttempts];
        default:
            return @"Estado desconhecido";
    }
}

#pragma mark - Configuration

- (void)setServerIP:(NSString *)ip {
    if (ip.length > 0) {
        _serverIP = [ip copy];
        writeLog(@"[WebRTCManager] IP do servidor definido para: %@", _serverIP);
    }
}

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    _targetResolution = resolution;
    [self.frameConverter setTargetResolution:resolution];
    
    writeLog(@"[WebRTCManager] Resolução alvo definida para %dx%d",
            resolution.width, resolution.height);
}

- (void)setTargetFrameRate:(float)frameRate {
    _targetFrameRate = frameRate;
    [self.frameConverter setTargetFrameRate:frameRate];
    
    writeLog(@"[WebRTCManager] Taxa de quadros alvo definida para %.1f fps", frameRate);
}

- (void)setAutoAdaptToCameraEnabled:(BOOL)enable {
    _autoAdaptToCameraResolution = enable;
    writeLog(@"[WebRTCManager] Auto-adaptação à câmera %@", enable ? @"ativada" : @"desativada");
}

#pragma mark - Connection Management

- (void)startWebRTC {
    // Verificar se já está conectado ou conectando
    if (_state == WebRTCManagerStateConnected ||
        _state == WebRTCManagerStateConnecting) {
        writeLog(@"[WebRTCManager] Já está conectado ou conectando, ignorando chamada");
        return;
    }
    
    // Resetar flag de desconexão pelo usuário
    self.userRequestedDisconnect = NO;
    
    writeLog(@"[WebRTCManager] Iniciando WebRTC");
    
    // Atualizar estado
    self.state = WebRTCManagerStateConnecting;
    
    // Limpar qualquer instância anterior
    [self stopWebRTC:NO];
    
    // Reset do conversor de frames
    [_frameConverter reset];
    
    // Iniciar temporizadores
    self.connectionStartTime = CACurrentMediaTime();
    self.hasReceivedFirstFrame = NO;
    self.lastFrameReceivedTime = CACurrentMediaTime();
    
    // Configurar WebRTC
    [self configureWebRTC];
    
    // Conectar ao WebSocket
    [self connectWebSocket];
    
    // Para depuração - mostrar uma imagem de teste enquanto aguarda conexão
    [self captureAndSendTestImage];
    
    // Iniciar timer para enviar imagens de teste
    [self startTimerWithName:@"frameTimer"
                    interval:1.0
                      target:self
                    selector:@selector(captureAndSendTestImage)
                     repeats:YES];
    
    // Timeout para conexão
    [self startTimerWithName:@"connectionTimeout"
                    interval:kConnectionTimeout
                      target:self
                    selector:@selector(handleConnectionTimeout)
                     repeats:NO];
    
    // Status check periódico
    [self startTimerWithName:@"statusCheck"
                    interval:kStatusCheckInterval
                      target:self
                    selector:@selector(checkWebRTCStatus)
                     repeats:YES];
    
    // Coleta periódica de estatísticas
    [self startTimerWithName:@"statsCollection"
                    interval:kStatsCollectionInterval
                      target:self
                    selector:@selector(gatherConnectionStats)
                     repeats:YES];
    
    // Monitoramento de frames
    [self startTimerWithName:@"frameCheck"
                    interval:kFrameMonitoringInterval
                      target:self
                    selector:@selector(checkFrameReceival)
                     repeats:YES];
}

- (void)stopWebRTC:(BOOL)userInitiated {
    // Se o usuário solicitou a desconexão, marcar flag
    if (userInitiated) {
        self.userRequestedDisconnect = YES;
    }
    
    writeLog(@"[WebRTCManager] Parando WebRTC (solicitado pelo usuário: %@)",
            userInitiated ? @"sim" : @"não");
    
    // Parar todos os timers
    [self stopAllTimers];
    
    // Desativar recepção de frames
    self.isReceivingFrames = NO;
    self.hasLocalStream = NO;
    
    // Limpar track de vídeo
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self.frameConverter];
        self.videoTrack = nil;
    }
    
    // Cancelar WebSocket
    if (self.webSocketTask) {
        NSURLSessionWebSocketTask *taskToCancel = self.webSocketTask;
        self.webSocketTask = nil;
        [taskToCancel cancel];
    }
    
    // Liberar sessão
    if (self.session) {
        NSURLSession *sessionToInvalidate = self.session;
        self.session = nil;
        [sessionToInvalidate invalidateAndCancel];
    }
    
    // Fechar conexão peer
    if (self.peerConnection) {
        RTCPeerConnection *connectionToClose = self.peerConnection;
        self.peerConnection = nil;
        [connectionToClose close];
    }
    
    // Limpar fábrica
    self.factory = nil;
    
    // Limpar roomId e clientId
    self.roomId = nil;
    self.clientId = nil;
    
    // Resetar flags
    self.hasReceivedFirstFrame = NO;
    
    // Se não está em reconexão, atualizar estado
    if (self.state != WebRTCManagerStateReconnecting || userInitiated) {
        self.state = WebRTCManagerStateDisconnected;
    }
}

- (void)gatherConnectionStats {
    if (!self.peerConnection || self.state != WebRTCManagerStateConnected) {
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        NSMutableDictionary *statsData = [NSMutableDictionary dictionary];
        int totalPacketsReceived = 0;
        int totalPacketsLost = 0;
        float frameRate = 0;
        int frameWidth = 0;
        int frameHeight = 0;
        NSString *codecName = @"unknown";
        
        // Processar estatísticas
        for (NSString *key in report.statistics.allKeys) {
            RTCStatistics *stats = report.statistics[key];
            NSDictionary *values = stats.values;
            
            // Stats para fluxo de entrada
            if ([stats.type isEqualToString:@"inbound-rtp"] &&
               [[values objectForKey:@"mediaType"] isEqualToString:@"video"]) {
                
                // Pacotes recebidos/perdidos
                if ([values objectForKey:@"packetsReceived"]) {
                    totalPacketsReceived += [[values objectForKey:@"packetsReceived"] intValue];
                    statsData[@"packetsReceived"] = [values objectForKey:@"packetsReceived"];
                }
                
                if ([values objectForKey:@"packetsLost"]) {
                    totalPacketsLost += [[values objectForKey:@"packetsLost"] intValue];
                    statsData[@"packetsLost"] = [values objectForKey:@"packetsLost"];
                }
                
                // Codec
                if ([values objectForKey:@"codecId"]) {
                    NSString *codecId = [values objectForKey:@"codecId"];
                    RTCStatistics *codecStats = report.statistics[codecId];
                    if (codecStats && [codecStats.values objectForKey:@"mimeType"]) {
                        id mimeTypeObj = [codecStats.values objectForKey:@"mimeType"];
                        if ([mimeTypeObj isKindOfClass:[NSString class]]) {
                            codecName = (NSString *)mimeTypeObj;
                            statsData[@"codec"] = codecName;
                        }
                    }
                }
            }
            
            // Stats para track de vídeo
            if ([stats.type isEqualToString:@"track"] &&
               [[values objectForKey:@"kind"] isEqualToString:@"video"]) {
                
                // Taxa de quadros
                if ([values objectForKey:@"framesPerSecond"]) {
                    frameRate = [[values objectForKey:@"framesPerSecond"] floatValue];
                    statsData[@"frameRate"] = @(frameRate);
                }
                
                // Dimensões do frame
                if ([values objectForKey:@"frameWidth"] && [values objectForKey:@"frameHeight"]) {
                    frameWidth = [[values objectForKey:@"frameWidth"] intValue];
                    frameHeight = [[values objectForKey:@"frameHeight"] intValue];
                    statsData[@"resolution"] = [NSString stringWithFormat:@"%dx%d", frameWidth, frameHeight];
                }
            }
        }
        
        // Calcular taxa de perda de pacotes
        float lossRate = 0;
        if (totalPacketsReceived + totalPacketsLost > 0) {
            lossRate = (float)totalPacketsLost / (totalPacketsReceived + totalPacketsLost) * 100.0f;
            statsData[@"lossRate"] = @(lossRate);
        }
        
        // Log de estatísticas relevantes a cada 5 coletas
        static int statsLogCount = 0;
        statsLogCount++;
        if (statsLogCount % 5 == 0) {
            writeLog(@"[WebRTCManager] Qualidade de vídeo: %dx%d @ %.1f fps, codec: %@",
                   frameWidth, frameHeight, frameRate, codecName);
            writeLog(@"[WebRTCManager] Estatísticas de rede: %d pacotes recebidos, %.1f%% perdidos",
                   totalPacketsReceived, lossRate);
            statsLogCount = 0;
        }
        
        // Atualizar UI com informações relevantes de qualidade
        if (frameWidth > 0 && frameHeight > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.isReceivingFrames) {
                    NSString *qualityInfo = [NSString stringWithFormat:@"%dx%d @ %.1ffps",
                                          frameWidth, frameHeight, frameRate];
                    [weakSelf.floatingWindow updateConnectionStatus:qualityInfo];
                }
            });
        }
    }];
}

- (void)checkWebRTCStatus {
    if (self.state == WebRTCManagerStateDisconnected) {
        return;
    }
    
    // Log menos frequente para reduzir spam nos logs
    static int checkCount = 0;
    checkCount++;
    
    if (checkCount % 5 == 0) {
        writeLog(@"[WebRTCManager] Verificando status WebRTC:");
        writeLog(@"  - PeerConnection: %@", self.peerConnection ? @"Inicializado" : @"NULL");
        writeLog(@"  - VideoTrack: %@", self.videoTrack ? @"Recebido" : @"NULL");
        writeLog(@"  - Estado: %@", [self stateToString:self.state]);
        writeLog(@"  - IsReceivingFrames: %@", self.isReceivingFrames ? @"Sim" : @"Não");
        
        if (self.peerConnection) {
            writeLog(@"  - ICE Connection State: %@", [self iceConnectionStateToString:self.peerConnection.iceConnectionState]);
            writeLog(@"  - Signaling State: %@", [self signalingStateToString:self.peerConnection.signalingState]);
        }
        checkCount = 0;
    }
    
    // Verificar se estamos conectados mas não recebendo frames
    if (self.state == WebRTCManagerStateConnected && !self.isReceivingFrames) {
        NSTimeInterval timeSinceLastFrame = CACurrentMediaTime() - self.lastFrameReceivedTime;
        
        // Se já recebemos frames antes mas agora paramos (depois de 5 segundos)
        if (self.hasReceivedFirstFrame && timeSinceLastFrame > 5.0) {
            writeLog(@"[WebRTCManager] Alerta: Sem frames recebidos nos últimos %.1f segundos", timeSinceLastFrame);
            
            // Tentar reconectar o renderer se tivermos o videoTrack
            if (self.videoTrack) {
                writeLog(@"[WebRTCManager] Tentando reconectar o renderer");
                [self.videoTrack removeRenderer:self.frameConverter];
                [self.videoTrack addRenderer:self.frameConverter];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.floatingWindow updateConnectionStatus:@"Sem frames recebidos - tentando reconectar"];
            });
        }
    }
    
    // Verificar se precisamos reconectar devido a problemas
    [self checkForReconnectionNeeded];
}

- (void)checkForReconnectionNeeded {
    // Se uma desconexão foi solicitada pelo usuário, não devemos tentar reconectar
    if (self.userRequestedDisconnect) {
        return;
    }
    
    // Verificar condições que requerem reconexão
    BOOL needsReconnection = NO;
    NSString *reason = @"";
    
    // Sem conexão peer
    if (!self.peerConnection && self.state != WebRTCManagerStateDisconnected) {
        needsReconnection = YES;
        reason = @"Sem conexão peer";
    }
    
    // Estado de erro
    else if (self.state == WebRTCManagerStateError) {
        needsReconnection = YES;
        reason = @"Estado de erro";
    }
    
    // Conexão ICE falhou
    else if (self.peerConnection &&
            (self.peerConnection.iceConnectionState == RTCIceConnectionStateFailed ||
            self.peerConnection.iceConnectionState == RTCIceConnectionStateDisconnected)) {
        needsReconnection = YES;
        reason = @"Falha na conexão ICE";
    }
    
    // Estado de sinalização incorreto
    else if (self.peerConnection && self.peerConnection.signalingState == RTCSignalingStateClosed) {
        needsReconnection = YES;
        reason = @"Estado de sinalização fechado";
    }
    
    // Se estava recebendo frames mas parou de receber por tempo demais
    else if (self.hasReceivedFirstFrame && self.state == WebRTCManagerStateConnected) {
        NSTimeInterval timeSinceLastFrame = CACurrentMediaTime() - self.lastFrameReceivedTime;
        if (timeSinceLastFrame > 10.0) {
            needsReconnection = YES;
            reason = @"Sem recebimento de frames por 10 segundos";
        }
    }
    
    // Se precisamos reconectar e não excedemos o número máximo de tentativas (ou ilimitado)
    if (needsReconnection && (kMaxReconnectAttempts == 0 || self.reconnectAttempts < kMaxReconnectAttempts)) {
        writeLog(@"[WebRTCManager] Necessário reconectar. Motivo: %@. Tentativa %d",
                reason, self.reconnectAttempts + 1);
        
        [self initiateReconnection];
    }
}

- (void)checkFrameReceival {
    if (self.state != WebRTCManagerStateConnected) {
        return;
    }
    
    NSTimeInterval timeSinceLastFrame = CACurrentMediaTime() - self.lastFrameReceivedTime;
    
    // Se conectado e não recebendo frames por mais de 5 segundos
    if (timeSinceLastFrame > 5.0) {
        writeLog(@"[WebRTCManager] Alerta: Sem frames recebidos por %.1f segundos", timeSinceLastFrame);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Sem quadros recebidos"];
        });
        
        // Marcar como não recebendo frames
        self.isReceivingFrames = NO;
    }
}

- (void)initiateReconnection {
    // Incrementar contador de tentativas
    self.reconnectAttempts++;
    
    // Atualizar estado
    self.state = WebRTCManagerStateReconnecting;
    
    writeLog(@"[WebRTCManager] Iniciando reconexão (tentativa %d)", self.reconnectAttempts);
    
    // Limpar recursos atuais, mas manter o estado de reconexão
    [self stopWebRTC:NO];
    
    // Programar reconexão com delay crescente (até 10 segundos)
    NSTimeInterval delay = MIN(kReconnectInterval * self.reconnectAttempts, 10.0);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Verificar se o usuário não desconectou manualmente enquanto esperávamos
        if (!self.userRequestedDisconnect) {
            [self startWebRTC];
        }
    });
}

- (void)handleConnectionTimeout {
    if (self.state == WebRTCManagerStateConnecting) {
        writeLog(@"[WebRTCManager] Timeout na inicialização do WebRTC após %.0f segundos", kConnectionTimeout);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Timeout na conexão"];
        });
        
        // Incrementar contador de falhas consecutivas
        self.consecutiveReconnectFailures++;
        
        // Se muitas falhas consecutivas, tentar com menos qualidade
        if (self.consecutiveReconnectFailures > 2) {
            writeLog(@"[WebRTCManager] Múltiplas falhas de conexão, reduzindo qualidade para próxima tentativa");
            
            // Reduzir resolução para 1080p
            if (self.targetResolution.width > 1920) {
                self.targetResolution.width = 1920;
                self.targetResolution.height = 1080;
                [self.frameConverter setTargetResolution:self.targetResolution];
            }
            // Reduzir framerate
            if (self.targetFrameRate > 30) {
                self.targetFrameRate = 30;
                [self.frameConverter setTargetFrameRate:self.targetFrameRate];
            }
        }
        
        // Iniciar processo de reconexão
        [self initiateReconnection];
    }
}

- (void)captureAndSendTestImage {
    // Somente mostrar o indicador de teste se não estiver recebendo frames reais
    if (self.state == WebRTCManagerStateConnected && self.isReceivingFrames) {
        return;
    }
    
    // Para testes - enviar uma imagem gerada para a visualização
    @autoreleasepool {
        CGSize size = CGSizeMake(320, 240);
        UIGraphicsBeginImageContextWithOptions(size, YES, 0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        
        // Verificar se o contexto foi criado corretamente
        if (!context) {
            writeLog(@"[WebRTCManager] Falha ao criar contexto gráfico para imagem de teste");
            return;
        }
        
        // Fundo preto
        CGContextSetFillColorWithColor(context, [UIColor blackColor].CGColor);
        CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));
        
        // Desenhar texto de timestamp
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                           dateStyle:NSDateFormatterShortStyle
                                                           timeStyle:NSDateFormatterMediumStyle];
        NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
        paragraphStyle.alignment = NSTextAlignmentCenter;
        
        NSDictionary *attributes = @{
            NSFontAttributeName: [UIFont systemFontOfSize:16],
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSParagraphStyleAttributeName: paragraphStyle
        };
        
        [timestamp drawInRect:CGRectMake(20, 100, 280, 40) withAttributes:attributes];
        
        // Status da conexão
        NSString *statusText;
        switch (self.state) {
            case WebRTCManagerStateConnected:
                statusText = self.isReceivingFrames ?
                   @"Conectado - Recebendo quadros" :
                   @"Conectado - Aguardando vídeo";
                break;
            case WebRTCManagerStateConnecting:
                statusText = @"Conectando ao servidor...";
                break;
            case WebRTCManagerStateReconnecting:
                statusText = [NSString stringWithFormat:@"Reconectando (tentativa %d)", self.reconnectAttempts];
                break;
            case WebRTCManagerStateError:
                statusText = @"Erro na conexão";
                break;
            default:
                statusText = @"Desconectado";
                break;
        }
        
        [statusText drawInRect:CGRectMake(20, 150, 280, 40) withAttributes:attributes];
        
        // Desenhar um círculo colorido que muda
        static float hue = 0.0;
        UIColor *color = [UIColor colorWithHue:hue saturation:1.0 brightness:1.0 alpha:1.0];
        CGContextSetFillColorWithColor(context, color.CGColor);
        CGContextFillEllipseInRect(context, CGRectMake(135, 40, 50, 50));
        hue += 0.05;
        if (hue > 1.0) hue = 0.0;
        
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.floatingWindow updatePreviewImage:image];
            });
        }
    }
}

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    return [self.frameConverter getLatestSampleBuffer];
}

- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position {
    writeLog(@"[WebRTCManager] Detectando câmera %@ para adaptação",
            position == AVCaptureDevicePositionFront ? @"frontal" : @"traseira");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Buscar dispositivo de câmera
        AVCaptureDevice *camera = nil;
        
        AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                mediaType:AVMediaTypeVideo
                                 position:position];
        
        NSArray<AVCaptureDevice *> *devices = discoverySession.devices;
        
        if (devices.count > 0) {
            camera = devices.firstObject;
        }
        
        // Se não encontrar o dispositivo específico, usar o padrão
        if (!camera) {
            writeLog(@"[WebRTCManager] Câmera %@ não encontrada, usando dispositivo padrão",
                   position == AVCaptureDevicePositionFront ? @"frontal" : @"traseira");
            camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        }
        
        if (!camera) {
            writeLog(@"[WebRTCManager] Nenhuma câmera disponível no dispositivo");
            return;
        }
        
        // Atualizar flag da câmera atual
        self.usingBackCamera = (position == AVCaptureDevicePositionBack);
        
        // Obter as capacidades da câmera
        [self extractCameraCapabilitiesAndAdapt:camera];
    });
}

- (void)extractCameraCapabilitiesAndAdapt:(AVCaptureDevice *)camera {
    NSError *error = nil;
    
    // Bloquear configuração para obter informações
    if ([camera lockForConfiguration:&error]) {
        // Obter formato ativo
        AVCaptureDeviceFormat *activeFormat = camera.activeFormat;
        
        // Dimensões
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription);
        
        // Taxa de quadros
        float maxFrameRate = 0;
        for (AVFrameRateRange *range in activeFormat.videoSupportedFrameRateRanges) {
            if (range.maxFrameRate > maxFrameRate) {
                maxFrameRate = range.maxFrameRate;
            }
        }
        
        // Log das capacidades
        writeLog(@"[WebRTCManager] Câmera detectada: %@", camera.localizedName);
        writeLog(@"[WebRTCManager] Formato ativo: %dx%d @ %.1f fps",
               dimensions.width, dimensions.height, maxFrameRate);
        
        // Verificar se a câmera suporta 4K
        BOOL supports4K = NO;
        for (AVCaptureDeviceFormat *format in camera.formats) {
            CMVideoDimensions formatDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            if (formatDimensions.width >= 3840 || formatDimensions.height >= 2160) {
                supports4K = YES;
                writeLog(@"[WebRTCManager] Câmera suporta 4K");
                break;
            }
        }
        
        // Desbloquear dispositivo
        [camera unlockForConfiguration];
        
        // Configurar adaptação
        dispatch_async(dispatch_get_main_queue(), ^{
            // Atualizar UI
            [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Adaptando para %dx%d",
                                                      dimensions.width, dimensions.height]];
            
            // Configurar o conversor para a resolução da câmera
            [self setTargetResolution:dimensions];
            [self setTargetFrameRate:maxFrameRate];
            
            // Se estamos conectados, tentar atualizar o stream para a nova resolução
            if (self.state == WebRTCManagerStateConnected && self.hasLocalStream) {
                // Se mudarmos de câmera, podemos precisar recriar os tracks
                [self updateVideoTrackWithNewCamera:camera];
            }
        });
    } else {
        writeLog(@"[WebRTCManager] Erro ao bloquear câmera para configuração: %@", error);
    }
}

- (void)updateVideoTrackWithNewCamera:(AVCaptureDevice *)camera {
    // Este método seria implementado para atualizar a resolução durante uma chamada ativa
    // mas não é trivial e pode necessitar de renegociação completa do PeerConnection
    // Nas versões mais recentes do WebRTC, é possível substituir apenas o capturer
    
    // Por enquanto, apenas logamos que seria necessário recriar a conexão
    writeLog(@"[WebRTCManager] A substituição de câmera durante uma conexão ativa requer reimplementação da conexão");
}

- (void)cameraDidChange:(NSNotification *)notification {
    // Acionado quando há uma mudança na câmera (como troca de câmera frontal/traseira)
    id device = notification.object;
    if ([device isKindOfClass:[AVCaptureDevice class]] &&
        [(AVCaptureDevice*)device hasMediaType:AVMediaTypeVideo]) {
        writeLog(@"[WebRTCManager] Câmera alterada para: %@", [(AVCaptureDevice*)device localizedName]);
        [self adaptToNativeCameraWithPosition:[(AVCaptureDevice*)device position]];
    }
}

- (void)orientationChanged:(NSNotification *)notification {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    if (UIDeviceOrientationIsLandscape(orientation) || UIDeviceOrientationIsPortrait(orientation)) {
        writeLog(@"[WebRTCManager] Orientação alterada para: %@",
                UIDeviceOrientationIsLandscape(orientation) ? @"Paisagem" : @"Retrato");
        
        // Atualizar a adaptação de resolução se tivermos uma câmera ativa
        if (self.autoAdaptToCameraResolution) {
            AVCaptureDevicePosition position = self.usingBackCamera ?
                AVCaptureDevicePositionBack : AVCaptureDevicePositionFront;
            [self adaptToNativeCameraWithPosition:position];
        }
    }
}

#pragma mark - WebRTC Configuration

- (void)configureWebRTC {
    writeLog(@"[WebRTCManager] Configurando WebRTC para alta qualidade 4K/60fps");
    
    // Configuração otimizada para WebRTC
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    
    // Para rede local, apenas um servidor STUN é suficiente
    config.iceServers = self.iceServers;
    
    // Configurações avançadas para melhor desempenho
    config.iceTransportPolicy = RTCIceTransportPolicyAll;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy =
    
