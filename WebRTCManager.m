#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "logger.h"

// Notificação usada para detectar mudanças de câmera
NSString *const kCameraChangeNotification = @"AVCaptureDeviceSubjectAreaDidChangeNotification";

@interface WebRTCManager ()
@property (nonatomic, assign, readwrite) WebRTCManagerState state;
@property (nonatomic, assign) BOOL isReceivingFrames;
@property (nonatomic, assign) int reconnectAttempts;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, assign) NSTimeInterval lastFrameReceivedTime;
@property (nonatomic, assign) BOOL userRequestedDisconnect;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;

// Gerenciamento de adaptação de formatos
@property (nonatomic, assign) AVCaptureDevicePosition currentCameraPosition;
@property (nonatomic, assign) OSType currentCameraFormat;
@property (nonatomic, assign) CMVideoDimensions currentCameraResolution;
@property (nonatomic, assign) BOOL iosCompatibilitySignalingEnabled;
@property (nonatomic, strong, readwrite) WebRTCFrameConverter *frameConverter;

// Timer management
@property (nonatomic, strong) NSTimer *statsTimer;
@end

@implementation WebRTCManager

#pragma mark - Initialization & Lifecycle

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        _floatingWindow = window;
        _state = WebRTCManagerStateDisconnected;
        _isReceivingFrames = NO;
        _reconnectAttempts = 0;
        _userRequestedDisconnect = NO;
        _serverIP = @"192.168.0.178"; // Default IP - pode ser personalizado
        _adaptationMode = WebRTCAdaptationModeCompatibility; // Default para compatibilidade com iOS
        _autoAdaptToCameraEnabled = YES; // Habilitar adaptação automática por padrão
        _iosCompatibilitySignalingEnabled = YES; // Habilitar sinalização de compatibilidade iOS
        
        // Inicializar o conversor de frames
        _frameConverter = [[WebRTCFrameConverter alloc] init];
        
        // Configurações padrão para câmera
        _currentCameraPosition = AVCaptureDevicePositionUnspecified;
        _currentCameraFormat = 0; // Formato inicialmente desconhecido
        _currentCameraResolution.width = 0;
        _currentCameraResolution.height = 0;
        
        // Inscrever-se para notificações de mudança de câmera
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleCameraChange:)
                                                     name:kCameraChangeNotification
                                                   object:nil];
        
        // Registrar para notificações de memória baixa
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleLowMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
        // Registrar para notificação de background (para limpar recursos)
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        
        // Registrar para retorno do background (para restaurar se necessário)
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppWillEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        
        writeLog(@"[WebRTCManager] Inicializado com suporte otimizado para formatos iOS");
    }
    return self;
}

// Método para lidar com entrada em background
- (void)handleAppDidEnterBackground {
    writeLog(@"[WebRTCManager] Aplicativo entrou em background, realizando limpeza preventiva");
    
    // Se estamos conectados, não desconectar completamente, apenas limpar recursos não essenciais
    if (self.state == WebRTCManagerStateConnected) {
        if (self.frameConverter) {
            [self.frameConverter performSafeCleanup];
        }
        
        // Aqui podemos fazer outras otimizações para economizar recursos em background
    }
}

// Método para lidar com retorno ao foreground
- (void)handleAppWillEnterForeground {
    writeLog(@"[WebRTCManager] Aplicativo retornou ao foreground");
    
    // Verificar se a conexão ainda está ativa
    if (self.state == WebRTCManagerStateConnected) {
        // Verificar se o WebSocket ainda está conectado
        if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
            writeLog(@"[WebRTCManager] Conexão perdida durante background, reconectando...");
            self.state = WebRTCManagerStateReconnecting;
            
            // Iniciar reconexão
            [self attemptReconnection];
        } else {
            // Enviar ping para verificar conexão
            @try {
                [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Erro no ping após retorno do background: %@", error);
                        self.state = WebRTCManagerStateReconnecting;
                        [self attemptReconnection];
                    }
                }];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Exceção ao enviar ping: %@", e);
                self.state = WebRTCManagerStateReconnecting;
                [self attemptReconnection];
            }
        }
    }
}

// Método para dealloc - adicionar ou modificar
- (void)dealloc {
    // Remover observadores de notificação
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // Garantir que tudo seja liberado
    [self stopWebRTC:YES];
    
    writeLog(@"[WebRTCManager] Objeto desalocado, recursos liberados");
}

#pragma mark - State Management

- (void)setState:(WebRTCManagerState)newState {
    if (_state == newState) {
        return;
    }
    
    WebRTCManagerState oldState = _state;
    
    // Usar KVO para notificar mudanças na propriedade
    [self willChangeValueForKey:@"state"];
    _state = newState;
    [self didChangeValueForKey:@"state"];
    
    // Log da transição
    writeLog(@"[WebRTCManager] Estado alterado: %@ -> %@",
             [self stateToString:oldState],
             [self stateToString:newState]);
    
    // Notificar FloatingWindow
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:[self statusMessageForState:newState]];
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
        case WebRTCManagerStateConnected: {
            NSString *formatInfo = @"";
            if (_frameConverter.detectedPixelFormat != IOSPixelFormatUnknown) {
                formatInfo = [NSString stringWithFormat:@" (%@)",
                             [WebRTCFrameConverter stringFromPixelFormat:_frameConverter.detectedPixelFormat]];
            }
            return self.isReceivingFrames ?
                [NSString stringWithFormat:@"Conectado - Recebendo stream%@", formatInfo] :
                @"Conectado - Aguardando stream";
        }
        case WebRTCManagerStateError:
            return @"Erro de conexão";
        case WebRTCManagerStateReconnecting:
            return [NSString stringWithFormat:@"Reconectando (%d)...", self.reconnectAttempts];
        default:
            return @"Estado desconhecido";
    }
}

- (void)monitorNetworkStatus {
    // Registrar para notificações de mudança de rede
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleNetworkStatusChange:)
                                                 name:@"com.apple.system.config.network_change"
                                               object:nil];
    
    writeLog(@"[WebRTCManager] Monitoramento de rede iniciado");
}

- (void)handleNetworkStatusChange:(NSNotification *)notification {
    writeLog(@"[WebRTCManager] Mudança de status de rede detectada");
    
    // Se estamos conectados ou conectando, verificar a integridade da conexão
    if (self.state == WebRTCManagerStateConnected || self.state == WebRTCManagerStateConnecting) {
        // Verificar se o WebSocket ainda está ativo
        if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
            writeLog(@"[WebRTCManager] WebSocket inativo após mudança de rede, iniciando reconexão");
            self.state = WebRTCManagerStateReconnecting;
            [self attemptReconnection];
        } else {
            // Enviar ping para verificar se a conexão ainda está ativa
            @try {
                [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Falha no ping após mudança de rede: %@", error);
                        self.state = WebRTCManagerStateReconnecting;
                        [self attemptReconnection];
                    } else {
                        writeLog(@"[WebRTCManager] Conexão confirmada após mudança de rede");
                    }
                }];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Exceção ao enviar ping: %@", e);
                self.state = WebRTCManagerStateReconnecting;
                [self attemptReconnection];
            }
        }
    }
}

#pragma mark - Camera Adaptation

- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position {
    _currentCameraPosition = position;
    
    if (!_autoAdaptToCameraEnabled) {
        writeLog(@"[WebRTCManager] Adaptação automática desativada, ignorando mudança de câmera");
        return;
    }
    
    writeLog(@"[WebRTCManager] Adaptando para câmera %@",
             position == AVCaptureDevicePositionFront ? @"frontal" : @"traseira");
    
    // Para uma implementação completa, devemos detectar o formato e resolução reais
    // da câmera ativa através do AVCaptureDevice. Esta é uma versão simplificada.
    
    // Determinar formato e resolução baseados na posição da câmera
    // (na implementação real, devemos consultar o AVCaptureDevice)
    OSType format;
    CMVideoDimensions resolution;
    
    if (position == AVCaptureDevicePositionFront) {
        // Câmera frontal geralmente usa formato YUV 4:2:0 full-range e resolução menor
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange; // '420f'
        resolution.width = 1280;
        resolution.height = 720;
    } else {
        // Câmera traseira geralmente suporta resolução máxima e formatos mais diversos
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange; // '420f'
        resolution.width = 1920;
        resolution.height = 1080;
    }
    
    _currentCameraFormat = format;
    _currentCameraResolution = resolution;
    
    // Notificar o conversor de frames sobre a mudança
    [_frameConverter adaptToNativeCameraFormat:format resolution:resolution];
    
    // Atualizar a interface do usuário com informações de formato
    [self updateFormatInfoInUI];
}

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    [_frameConverter setTargetResolution:resolution];
}

- (void)setTargetFrameRate:(float)frameRate {
    [_frameConverter setTargetFrameRate:frameRate];
}

- (void)setAutoAdaptToCameraEnabled:(BOOL)enabled {
    _autoAdaptToCameraEnabled = enabled;
    writeLog(@"[WebRTCManager] Adaptação automática de câmera %@",
             enabled ? @"ativada" : @"desativada");
    
    // Se ativado e já temos informações da câmera, adaptar imediatamente
    if (enabled && _currentCameraPosition != AVCaptureDevicePositionUnspecified) {
        [self adaptToNativeCameraWithPosition:_currentCameraPosition];
    }
}

- (void)handleCameraChange:(NSNotification *)notification {
    // Processar mudança na câmera (chamado quando há uma notificação de alteração)
    if (!_autoAdaptToCameraEnabled) return;
    
    AVCaptureDevice *device = notification.object;
    if ([device hasMediaType:AVMediaTypeVideo]) {
        writeLog(@"[WebRTCManager] Detectada mudança na câmera: %@", device.localizedName);
        [self adaptToNativeCameraWithPosition:device.position];
    }
}

- (void)updateFormatInfoInUI {
    if (!self.floatingWindow) return;
    
    // Atualizar informações de formato na UI, se a FloatingWindow tiver métodos específicos
    // Isso é uma implementação genérica - ajuste conforme sua FloatingWindow
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Atualizar status com informações de formato
        [self.floatingWindow updateConnectionStatus:[self statusMessageForState:self.state]];
        
        // Se houver método específico na FloatingWindow para atualizar informações de formato
        if ([self.floatingWindow respondsToSelector:@selector(updateFormatInfo:)]) {
            NSString *formatInfo = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
            [self.floatingWindow performSelector:@selector(updateFormatInfo:) withObject:formatInfo];
        }
    });
}

#pragma mark - Connection Management

- (void)startWebRTC {
    @try {
        // Verificar se já está conectado ou conectando
        if (self.state == WebRTCManagerStateConnected || self.state == WebRTCManagerStateConnecting) {
            writeLog(@"[WebRTCManager] Já está conectado ou conectando, ignorando chamada");
            return;
        }
        
        // Verificar IP do servidor
        if (self.serverIP == nil || self.serverIP.length == 0) {
            writeLog(@"[WebRTCManager] IP do servidor inválido, usando padrão");
            self.serverIP = @"192.168.0.178"; // Default IP
        }
        
        // Resetar flag de desconexão pelo usuário
        self.userRequestedDisconnect = NO;
        
        writeLog(@"[WebRTCManager] Iniciando WebRTC (Modo: %@)",
                [self adaptationModeToString:self.adaptationMode]);
        
        // Atualizar estado
        self.state = WebRTCManagerStateConnecting;
        
        // Limpeza explícita de recursos anteriores para evitar conexões duplicadas
        [self cleanupResources];
        
        // Configurar WebRTC
        [self configureWebRTC];
        
        // Conectar ao WebSocket
        [self connectWebSocket];
        
        // Iniciar timer para estatísticas
        [self startStatsTimer];
        
        // Iniciar monitoramento periódico de recursos
        __weak typeof(self) weakSelf = self;
        dispatch_queue_t monitorQueue = dispatch_queue_create("com.webrtc.resourcemonitor", DISPATCH_QUEUE_SERIAL);
        
        if (self.resourceMonitorTimer) {
            dispatch_source_cancel(self.resourceMonitorTimer);
            self.resourceMonitorTimer = nil;
        }
        
        self.resourceMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, monitorQueue);
        dispatch_source_set_timer(self.resourceMonitorTimer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(self.resourceMonitorTimer, ^{
            if (weakSelf.frameConverter) {
                // Verificar vazamentos e desequilíbrios de recursos
                [weakSelf checkResourceBalance];
                [weakSelf monitorVideoStatistics];
            }
        });
        dispatch_resume(self.resourceMonitorTimer);
        
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao iniciar WebRTC: %@", exception);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Erro ao iniciar WebRTC"];
        });
        self.state = WebRTCManagerStateError;
    }
}

- (void)configureWebRTC {
    @try {
        writeLog(@"[WebRTCManager] Configurando WebRTC com otimizações para iOS");
        
        // Configuração adaptada para integração com iOS
        RTCConfiguration *config = [[RTCConfiguration alloc] init];
        
        // Para rede local, servidores STUN são suficientes
        config.iceServers = @[
            [[RTCIceServer alloc] initWithURLStrings:@[
                @"stun:stun.l.google.com:19302",
                @"stun:stun1.l.google.com:19302",
                @"stun:stun2.l.google.com:19302",
                @"stun:stun3.l.google.com:19302"
            ]]
        ];
        
        // Configurações de ICE otimizadas para redes locais e iOS
        config.iceTransportPolicy = RTCIceTransportPolicyAll;
        config.bundlePolicy = RTCBundlePolicyMaxBundle;
        config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
        config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled; // Ativar candidatos TCP para redes locais
        config.candidateNetworkPolicy = RTCCandidateNetworkPolicyAll;
        config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
        
        // Aumentar o pool de candidatos para melhorar a confiabilidade em rede local
        config.iceCandidatePoolSize = 2; // Aumentar para 2 (era 0)
                
        // Inicializar a fábrica com configurações específicas para a plataforma
        RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        if (!decoderFactory) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar decoderFactory");
            return;
        }
        
        RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        if (!encoderFactory) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar encoderFactory");
            return;
        }
        
        // Configurar fábrica para priorizar codecs e formatos compatíveis com iOS
        self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                  decoderFactory:decoderFactory];
        if (!self.factory) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar PeerConnectionFactory");
            return;
        }
        
        // Configurar para alta qualidade de vídeo com compatibilidade iOS
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                          initWithMandatoryConstraints:@{
                                              @"OfferToReceiveVideo": @"true",
                                              @"OfferToReceiveAudio": @"false"
                                          }
                                          optionalConstraints:@{
                                              @"DtlsSrtpKeyAgreement": @"true", // Melhora segurança e compatibilidade
                                              @"RtpDataChannels": @"false",  // Não precisamos de canais de dados RTP
                                              @"internalSctpDataChannels": @"false" // Não precisamos de canais SCTP
                                          }];
        
        self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                               constraints:constraints
                                                                  delegate:self];
        
        if (!self.peerConnection) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar conexão peer");
            return;
        }
        
        [self monitorNetworkStatus];
        
        writeLog(@"[WebRTCManager] Conexão peer criada com sucesso");
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCManager] Exceção ao configurar WebRTC: %@", exception);
        self.state = WebRTCManagerStateError;
    }
}

- (void)stopWebRTC:(BOOL)userInitiated {
    // Se o usuário solicitou a desconexão, marcar flag
    if (userInitiated) {
        self.userRequestedDisconnect = YES;
    }
    
    writeLog(@"[WebRTCManager] Parando WebRTC (solicitado pelo usuário: %@)",
            userInitiated ? @"sim" : @"não");
    
    // Solicitar limpeza segura do conversor de frames primeiro
    if (self.frameConverter) {
        [self.frameConverter performSafeCleanup];
    }
    
    // Enviar bye primeiro antes de limpar conexões
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        [self sendByeMessage];
        
        // Esperar um pouco para ter certeza que a mensagem bye será enviada
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self cleanupResources];
        });
    } else {
        // Se não houver conexão ativa, limpar recursos imediatamente
        [self cleanupResources];
    }
}

// Novo método para gerenciar situações de baixa memória
- (void)handleLowMemoryWarning {
    writeLog(@"[WebRTCManager] Aviso de memória baixa recebido");
    
    // Realizar limpeza de recursos não essenciais
    if (self.frameConverter) {
        [self.frameConverter performSafeCleanup];
    }
    
    // Limpar qualquer cache interno do WebRTCManager
    // [Adicionar aqui qualquer limpeza específica do WebRTCManager]
}

// Isolamento da limpeza de recursos
- (void)cleanupResources {
    // Adicionar um log mais detalhado para diagnóstico
    writeLog(@"[WebRTCManager] Realizando limpeza completa de recursos");
    
    // Primeiro, garantir que o conversor de frames seja limpo adequadamente
    if (self.frameConverter) {
        // Primeiro chamar reset para liberar buffers internos
        [self.frameConverter reset];
        
        // Depois executar limpeza segura
        [self.frameConverter performSafeCleanup];
        
        // Se estiver realmente fechando (não reconectando), remover referências
        if (!self.isReconnecting) {
            [self removeRendererFromVideoTrack:self.frameConverter];
            self.frameConverter = nil;
        }
    }
    
    // Parar timers
    [self stopStatsTimer];
    
    // Se timer de monitoramento de recursos está ativo, cancelar
    if (_resourceMonitorTimer) {
        dispatch_source_cancel(_resourceMonitorTimer);
        _resourceMonitorTimer = nil;
    }
    
    // Desativar recepção de frames
    self.isReceivingFrames = NO;
    if (self.floatingWindow) {
        self.floatingWindow.isReceivingFrames = NO;
    }
    
    // Limpar track de vídeo com verificações mais robustas
    if (self.videoTrack) {
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            // Remover o videoTrack da view
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.floatingWindow respondsToSelector:@selector(videoView)]) {
                    RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                    if (videoView) {
                        @try {
                            [self.videoTrack removeRenderer:videoView];
                        } @catch (NSException *e) {
                            writeLog(@"[WebRTCManager] Exceção ao remover videoView do track: %@", e);
                        }
                        videoView.backgroundColor = [UIColor blackColor];
                    }
                }
            });
        }
        
        // Remover frameConverter como renderer de forma segura
        if (self.frameConverter) {
            @try {
                [self.videoTrack removeRenderer:self.frameConverter];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Exceção ao remover frameConverter do track: %@", e);
            }
        }
        
        self.videoTrack = nil;
    }
    
    // Cancelar WebSocket com tratamento de erros
    if (self.webSocketTask) {
        @try {
            NSURLSessionWebSocketTask *taskToCancel = self.webSocketTask;
            self.webSocketTask = nil;
            [taskToCancel cancel];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao cancelar webSocketTask: %@", e);
        }
    }
    
    // Liberar sessão com tratamento de erros
    if (self.session) {
        @try {
            NSURLSession *sessionToInvalidate = self.session;
            self.session = nil;
            [sessionToInvalidate invalidateAndCancel];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao invalidar session: %@", e);
        }
    }
    
    // Fechar conexão peer com tratamento de erros
    if (self.peerConnection) {
        @try {
            RTCPeerConnection *connectionToClose = self.peerConnection;
            self.peerConnection = nil;
            [connectionToClose close];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao fechar peerConnection: %@", e);
        }
    }
    
    // Limpar fábrica
    self.factory = nil;
    
    // Limpar roomId e clientId
    self.roomId = nil;
    self.clientId = nil;
    
    // Se não está em reconexão, atualizar estado
    if (self.state != WebRTCManagerStateReconnecting || self.userRequestedDisconnect) {
        self.state = WebRTCManagerStateDisconnected;
    }
    
    // Forçar um ciclo de coleta de lixo para ajudar a liberar recursos
    @autoreleasepool {
        // Executa um ciclo vazio de autorelease pool
    }
    
    writeLog(@"[WebRTCManager] Limpeza de recursos concluída");
}

#pragma mark - Timer Management

- (void)startStatsTimer {
    // Parar timer existente se houver
    [self stopStatsTimer];
    
    // Criar novo timer para coleta de estatísticas
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(collectStats)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)stopStatsTimer {
    if (self.statsTimer) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
}

- (void)collectStats {
    if (!self.peerConnection) {
        return;
    }
    
    [self monitorVideoStatistics];
}

#pragma mark - WebSocket Connection

- (void)connectWebSocket {
    @try {
        // URL para o servidor
        NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
        NSURL *url = [NSURL URLWithString:urlString];
        
        // Configurar URL Request com timeouts aumentados
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 60.0; // Aumentar para 60 segundos
        
        // Configurar a sessão com timeout mais longo
        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = 60.0;     // 60 segundos
        sessionConfig.timeoutIntervalForResource = 120.0;   // 2 minutos
        
        // Criar sessão e task WebSocket
        if (self.session) {
            [self.session invalidateAndCancel];
        }
        self.session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                     delegate:self
                                                delegateQueue:[NSOperationQueue mainQueue]];
        
        self.webSocketTask = [self.session webSocketTaskWithRequest:request];
        
        // Iniciar recepção de mensagens
        [self receiveWebSocketMessage];
        
        // Conectar
        [self.webSocketTask resume];
        
        // Depois que a conexão for estabelecida, enviar JOIN com um pequeno delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendJoinMessage];
        });
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCManager] Exceção ao conectar WebSocket: %@", exception);
        self.state = WebRTCManagerStateError;
    }
}

// Novo método separado para enviar JOIN
- (void)sendJoinMessage {
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        NSMutableDictionary *joinMessage = [@{
            @"type": @"join",
            @"roomId": self.roomId ?: @"ios-camera",
            @"deviceType": @"ios",
            @"reconnect": @(self.reconnectAttempts > 0)
        } mutableCopy];
        
        // Incluir informações de capacidades iOS
        if (self.iosCompatibilitySignalingEnabled) {
            joinMessage[@"capabilities"] = [self getiOSCapabilitiesInfo];
        }
        
        [self sendWebSocketMessage:joinMessage];
        
        writeLog(@"[WebRTCManager] Enviada mensagem de JOIN para a sala: %@", self.roomId ?: @"ios-camera");
    }
}

- (NSDictionary *)getiOSCapabilitiesInfo {
    // Preparar informações sobre capacidades e formatos suportados pelo iOS
    // para ajudar o servidor a otimizar a conexão
    return @{
        @"preferredPixelFormats": @[
            @"420f",  // YUV 4:2:0 full-range (formato preferido)
            @"420v",  // YUV 4:2:0 video-range
            @"BGRA"   // 32-bit BGRA
        ],
        @"preferredCodec": @"H264",
        @"preferredH264Profiles": @[
            @"42e01f", // Baseline (compatível com iOS)
            @"42001f", // Constrained Baseline
            @"640c1f"  // High
        ],
        @"adaptationMode": [self adaptationModeToString:self.adaptationMode],
        @"supportedResolutions": @[
            @{@"width": @1920, @"height": @1080},
            @{@"width": @1280, @"height": @720},
            @{@"width": @3840, @"height": @2160}
        ],
        @"currentFormat": [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat],
        @"deviceInfo": @{
            @"model": [[UIDevice currentDevice] model],
            @"systemVersion": [[UIDevice currentDevice] systemVersion]
        }
    };
}

- (NSString *)adaptationModeToString:(WebRTCAdaptationMode)mode {
    switch (mode) {
        case WebRTCAdaptationModeAuto:
            return @"auto";
        case WebRTCAdaptationModePerformance:
            return @"performance";
        case WebRTCAdaptationModeQuality:
            return @"quality";
        case WebRTCAdaptationModeCompatibility:
            return @"compatibility";
        default:
            return @"unknown";
    }
}

- (void)startKeepAliveTimer {
    // Limpar intervalo existente
    if (_keepAliveTimer) {
        [_keepAliveTimer invalidate];
        _keepAliveTimer = nil;
    }
    
    // Usar intervalo exato de 2 segundos para sincronizar com o servidor
    _keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(sendKeepAlive)
                                                    userInfo:nil
                                                     repeats:YES];
    
    // Usar runloop específico para garantir que o timer continue mesmo durante reconexões
    [[NSRunLoop mainRunLoop] addTimer:_keepAliveTimer forMode:NSRunLoopCommonModes];
    
    // Executar imediatamente
    [self sendKeepAlive];
}

- (void)sendKeepAlive {
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        // Enviar ping nativo WebSocket
        [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
            if (error) {
                writeErrorLog(@"[WebRTCManager] Erro ao receber pong: %@", error);
            }
        }];
        
        // Também enviar mensagem JSON ping (para compatibilidade total)
        [self sendWebSocketMessage:@{
            @"type": @"ping",
            @"roomId": self.roomId ?: @"ios-camera",
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000),
            @"deviceInfo": @{
                @"reconnectAttempts": @(self.reconnectAttempts),
                @"isReceivingFrames": @(self.isReceivingFrames)
            }
        }];
        
        writeVerboseLog(@"[WebRTCManager] Enviando mensagem keep-alive (ping)");
    }
}

// Método para enviar mensagem de bye ao servidor
- (void)sendByeMessage {
    @try {
        if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
            writeLog(@"[WebRTCManager] Não foi possível enviar 'bye', WebSocket não está conectado");
            return;
        }
        
        // Log de debug
        writeLog(@"[WebRTCManager] Enviando mensagem 'bye' para o servidor");
        
        // Criar mensagem de bye
        NSDictionary *byeMessage = @{
            @"type": @"bye",
            @"roomId": self.roomId ?: @"ios-camera"
        };
        
        // Serializar para JSON
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:byeMessage options:0 error:&error];
        
        if (error) {
            writeErrorLog(@"[WebRTCManager] Erro ao serializar mensagem bye: %@", error);
            return;
        }
        
        // Converter para string
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        
        // Usar dispatch_semaphore para garantir que a mensagem seja enviada antes de prosseguir
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        // Enviar mensagem e aguardar confirmação
        [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                    completionHandler:^(NSError * _Nullable sendError) {
            if (sendError) {
                writeErrorLog(@"[WebRTCManager] Erro ao enviar bye: %@", sendError);
            } else {
                writeLog(@"[WebRTCManager] Mensagem 'bye' enviada com sucesso");
            }
            dispatch_semaphore_signal(semaphore);
        }];
        
        // Esperar até 2 segundos para garantir que a mensagem seja enviada
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCManager] Exceção ao enviar bye: %@", exception);
    }
}

- (void)sendWebSocketMessage:(NSDictionary *)message {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        writeLog(@"[WebRTCManager] Tentativa de enviar mensagem com WebSocket não conectado");
        return;
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message
                                                      options:0
                                                        error:&error];
    if (error) {
        writeLog(@"[WebRTCManager] Erro ao serializar mensagem JSON: %@", error);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                    completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao enviar mensagem WebSocket: %@", error);
        }
    }];
}

- (void)receiveWebSocketMessage {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao receber mensagem WebSocket: %@", error);
            
            // Se o WebSocket estiver fechado por erro, tentar reconectar
            if (weakSelf.webSocketTask.state != NSURLSessionTaskStateRunning && !weakSelf.userRequestedDisconnect) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.state = WebRTCManagerStateError;
                    // Iniciar reconexão se não estiver explicitamente desconectado pelo usuário
                    if (!weakSelf.userRequestedDisconnect) {
                        [weakSelf startReconnectionTimer];
                    }
                });
            }
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *jsonData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError = nil;
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                     options:0
                                                                       error:&jsonError];
            
            if (jsonError) {
                writeLog(@"[WebRTCManager] Erro ao analisar mensagem JSON: %@", jsonError);
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleWebSocketMessage:jsonDict];
            });
        }
        
        // Continuar recebendo mensagens
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveWebSocketMessage];
        }
    }];
}

- (void)handleWebSocketMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    
    if (!type) {
        writeLog(@"[WebRTCManager] Mensagem recebida sem tipo");
        return;
    }
    
    writeLog(@"[WebRTCManager] Mensagem recebida: %@", type);
    
    if ([type isEqualToString:@"offer"]) {
        [self handleOfferMessage:message];
    } else if ([type isEqualToString:@"answer"]) {
        [self handleAnswerMessage:message];
    } else if ([type isEqualToString:@"ice-candidate"]) {
        [self handleCandidateMessage:message];
    } else if ([type isEqualToString:@"user-joined"]) {
        // Detectar se o cliente que entrou é um dispositivo web/transmissor
        NSString *deviceType = message[@"deviceType"];
        if ([deviceType isEqualToString:@"web"]) {
            writeLog(@"[WebRTCManager] Transmissor web detectado: %@", message[@"userId"]);
        } else {
            writeLog(@"[WebRTCManager] Novo usuário entrou na sala: %@", message[@"userId"]);
        }
    } else if ([type isEqualToString:@"user-left"]) {
        writeLog(@"[WebRTCManager] Usuário saiu da sala: %@", message[@"userId"]);
    } else if ([type isEqualToString:@"ping"]) {
        // Responder imediatamente com uma mensagem pong
        [self sendWebSocketMessage:@{
            @"type": @"pong",
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000),
            @"roomId": self.roomId ?: @"ios-camera"
        }];
        writeVerboseLog(@"[WebRTCManager] Respondeu ao ping com pong");
    } else if ([type isEqualToString:@"pong"]) {
        // Resposta ao ping - atualizar timestamp de última resposta
        writeVerboseLog(@"[WebRTCManager] Pong recebido do servidor");
        
        // Resetar contador de reconexão quando recebemos pong (confirma conexão ativa)
        self.reconnectionAttempts = 0;
        
        // Se estiver tentando reconectar, mas recebeu pong, significa que a conexão está ok
        if (self.isReconnecting) {
            self.isReconnecting = NO;
            self.state = WebRTCManagerStateConnected;
            writeLog(@"[WebRTCManager] Conexão confirmada via pong durante reconexão");
        }
    } else if ([type isEqualToString:@"room-info"]) {
        // Processa informações da sala
        writeVerboseLog(@"[WebRTCManager] Informações da sala recebidas: %@", message[@"clients"]);
    } else if ([type isEqualToString:@"error"]) {
        writeLog(@"[WebRTCManager] Erro recebido do servidor: %@", message[@"message"]);
        [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Erro: %@", message[@"message"]]];
    } else if ([type isEqualToString:@"ios-capabilities-update"]) {
        // Receber atualização de capacidades de algum cliente iOS
        [self handleIOSCapabilitiesUpdate:message];
    } else {
        writeLog(@"[WebRTCManager] Tipo de mensagem desconhecido: %@", type);
    }
}

- (void)handleIOSCapabilitiesUpdate:(NSDictionary *)message {
    // Processar informações de capacidades de outro dispositivo iOS na sala
    if (!message[@"capabilities"]) return;
    
    NSDictionary *capabilities = message[@"capabilities"];
    writeLog(@"[WebRTCManager] Recebidas capacidades de outro dispositivo iOS: %@", capabilities);
    
    // Ajustar configurações com base nas capacidades recebidas
    // Isso é útil para otimizar a comunicação entre múltiplos dispositivos iOS
    if (capabilities[@"preferredPixelFormats"]) {
        NSArray *formats = capabilities[@"preferredPixelFormats"];
        // Atualizar formatos preferidos para comunicação iOS-iOS, se necessário
        writeLog(@"[WebRTCManager] Formatos de pixel preferidos pelo outro dispositivo: %@", formats);
    }
}

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Recebida oferta, mas não há conexão peer");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Oferta recebida sem SDP");
        return;
    }
    
    // Analisar a oferta SDP para extrair informações de qualidade
    [self logSdpDetails:sdp type:@"Offer"];
    
    // Verificar se o transmissor está enviando informações de compatibilidade
    //BOOL hasIOSOptimization = NO;
    if (message[@"offerInfo"]) {
        NSDictionary *offerInfo = message[@"offerInfo"];
        BOOL optimizedForIOS = [offerInfo[@"optimizedForIOS"] boolValue];
        if (optimizedForIOS) {
            //hasIOSOptimization = YES;
            writeLog(@"[WebRTCManager] Oferta tem otimizações específicas para iOS");
        }
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao definir descrição remota: %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] Descrição remota definida com sucesso, criando resposta");
        
        // Configurar restrições para resposta, otimizando para iOS
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        } optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints
                               completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
            if (error) {
                writeLog(@"[WebRTCManager] Erro ao criar resposta: %@", error);
                return;
            }
            
            // Log das informações da resposta SDP
            [weakSelf logSdpDetails:sdp.sdp type:@"Answer"];
            
            // Incluir informações de compatibilidade iOS na resposta
            NSMutableDictionary *answerMetadata = [NSMutableDictionary dictionary];
            if (weakSelf.iosCompatibilitySignalingEnabled) {
                // Adicionar informações sobre formato de pixel atual
                answerMetadata[@"pixelFormat"] = [WebRTCFrameConverter stringFromPixelFormat:weakSelf.frameConverter.detectedPixelFormat];
                
                // Adicionar preferências para comunicação com iOS
                answerMetadata[@"h264Profile"] = @"42e01f"; // Baseline (compatível com iOS)
                answerMetadata[@"adaptationMode"] = [weakSelf adaptationModeToString:weakSelf.adaptationMode];
            }
            
            // Definir descrição local
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro ao definir descrição local: %@", error);
                    return;
                }
                
                // Enviar resposta para o servidor
                NSMutableDictionary *responseMessage = [@{
                    @"type": @"answer",
                    @"sdp": sdp.sdp,
                    @"roomId": weakSelf.roomId ?: @"ios-camera",
                    @"senderDeviceType": @"ios"
                } mutableCopy];
                
                // Incluir metadados iOS se habilitado
                if (weakSelf.iosCompatibilitySignalingEnabled) {
                    responseMessage[@"answerMetadata"] = answerMetadata;
                }
                
                [weakSelf sendWebSocketMessage:responseMessage];
                
                // Usar weakSelf em vez de self para evitar retain cycle
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.state = WebRTCManagerStateConnected;
                });
            }];
        }];
    }];
}

- (void)handleAnswerMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Resposta recebida, mas não há conexão peer");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Resposta recebida sem SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao definir descrição remota (resposta): %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] Resposta remota definida com sucesso");
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.state = WebRTCManagerStateConnected;
        });
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Candidato recebido, mas não há conexão peer");
        return;
    }
    
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) {
        writeLog(@"[WebRTCManager] Candidato recebido com parâmetros inválidos");
        return;
    }
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                         sdpMLineIndex:[sdpMLineIndex intValue]
                                                                sdpMid:sdpMid];
    
    [self.peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao adicionar candidato Ice: %@", error);
            return;
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCManager] WebSocket conectado");
    
    // Redefinir contador de tentativas de reconexão quando conectado com sucesso
    self.reconnectAttempts = 0;
    
    if (!self.userRequestedDisconnect) {
        // Enviar mensagem de JOIN
        self.roomId = self.roomId ?: @"ios-camera";
        
        // Incluir informações de capacidades iOS se habilitado
        NSMutableDictionary *joinMessage = [@{
            @"type": @"join",
            @"roomId": self.roomId,
            @"deviceType": @"ios"
        } mutableCopy];
        
        if (self.iosCompatibilitySignalingEnabled) {
            joinMessage[@"capabilities"] = [self getiOSCapabilitiesInfo];
        }
        
        [self sendWebSocketMessage:joinMessage];
        
        writeLog(@"[WebRTCManager] Enviada mensagem de JOIN para a sala: %@", self.roomId);
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Desconhecido";
    writeLog(@"[WebRTCManager] WebSocket fechado com código: %ld, motivo: %@", (long)closeCode, reasonStr);
    
    // Se a desconexão não foi solicitada pelo usuário, atualizar estado
    if (!self.userRequestedDisconnect) {
        self.state = WebRTCManagerStateDisconnected;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        // Verificar erro específico de timeout
        if ([error.domain isEqualToString:NSURLErrorDomain] &&
            (error.code == NSURLErrorTimedOut || error.code == NSURLErrorNetworkConnectionLost)) {
            writeLog(@"[WebRTCManager] Timeout ou perda de conexão detectado: %@", error);
            
            // Verificar se já estamos em processo de reconexão
            if (!self.isReconnecting && !self.userRequestedDisconnect) {
                self.state = WebRTCManagerStateReconnecting;
                [self startReconnectionTimer];
            }
        } else {
            writeLog(@"[WebRTCManager] WebSocket completou com erro: %@", error);
            
            if (!self.userRequestedDisconnect) {
                self.state = WebRTCManagerStateError;
                [self startReconnectionTimer];
            }
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Candidato Ice gerado: %@", candidate.sdp);
    
    // Enviar candidato Ice para o servidor
    [self sendWebSocketMessage:@{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": self.roomId ?: @"ios-camera"
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    writeLog(@"[WebRTCManager] Candidatos Ice removidos: %lu", (unsigned long)candidates.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *stateString = [self iceConnectionStateToString:newState];
    writeLog(@"[WebRTCManager] Estado da conexão Ice alterado: %@", stateString);
    
    switch (newState) {
        case RTCIceConnectionStateConnected:
        case RTCIceConnectionStateCompleted:
            self.state = WebRTCManagerStateConnected;
            // Resetar contador de tentativas quando conectado com sucesso
            self.reconnectionAttempts = 0;
            self.isReconnecting = NO;
            break;
            
        case RTCIceConnectionStateFailed:
        case RTCIceConnectionStateDisconnected:
            if (!self.userRequestedDisconnect && !self.isReconnecting) {
                // Iniciar processo de reconexão
                [self startReconnectionTimer];
            }
            break;
            
        case RTCIceConnectionStateClosed:
            if (!self.userRequestedDisconnect) {
                self.state = WebRTCManagerStateError;
            }
            break;
            
        default:
            break;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    writeLog(@"[WebRTCManager] Estado de coleta Ice alterado: %@", [self iceGatheringStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {
    writeLog(@"[WebRTCManager] Estado de sinalização alterado: %@", [self signalingStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream adicionada: %@ (áudio: %lu, vídeo: %lu)",
            stream.streamId, (unsigned long)stream.audioTracks.count, (unsigned long)stream.videoTracks.count);
    
    // Verificar se a stream tem faixas de vídeo
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        writeLog(@"[WebRTCManager] Faixa de vídeo recebida: %@", self.videoTrack.trackId);
        
        // Adicionar o videoTrack ao RTCMTLVideoView
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                if (videoView) {
                    [self.videoTrack addRenderer:videoView];
                    
                    // Adicionar o track também ao conversor de frames para processamento
                    [self.videoTrack addRenderer:self.frameConverter];
                    
                    // Parar indicador de carregamento
                    UIActivityIndicatorView *loadingIndicator = [self.floatingWindow valueForKey:@"loadingIndicator"];
                    if (loadingIndicator) {
                        [loadingIndicator stopAnimating];
                    }
                    
                    // Atualizar flag
                    self.isReceivingFrames = YES;
                    self.floatingWindow.isReceivingFrames = YES;
                    
                    // Atualizar status
                    [self.floatingWindow updateConnectionStatus:@"Conectado - Recebendo vídeo"];
                }
            });
        }
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream removida: %@", stream.streamId);
    
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
            if (videoView) {
                [self.videoTrack removeRenderer:videoView];
                // Remover do conversor de frames também
                [self.videoTrack removeRenderer:self.frameConverter];
            }
        }
        self.videoTrack = nil;
        self.isReceivingFrames = NO;
    }
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Necessária renegociação");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    writeLog(@"[WebRTCManager] Data channel aberto: %@", dataChannel.label);
}

#pragma mark - Helper Methods

- (NSString *)iceConnectionStateToString:(RTCIceConnectionState)state {
    switch (state) {
        case RTCIceConnectionStateNew: return @"Novo";
        case RTCIceConnectionStateChecking: return @"Verificando";
        case RTCIceConnectionStateConnected: return @"Conectado";
        case RTCIceConnectionStateCompleted: return @"Completo";
        case RTCIceConnectionStateFailed: return @"Falha";
        case RTCIceConnectionStateDisconnected: return @"Desconectado";
        case RTCIceConnectionStateClosed: return @"Fechado";
        case RTCIceConnectionStateCount: return @"Contagem";
        default: return @"Desconhecido";
    }
}

- (NSString *)iceGatheringStateToString:(RTCIceGatheringState)state {
    switch (state) {
        case RTCIceGatheringStateNew: return @"Novo";
        case RTCIceGatheringStateGathering: return @"Coletando";
        case RTCIceGatheringStateComplete: return @"Completo";
        default: return @"Desconhecido";
    }
}

- (NSString *)signalingStateToString:(RTCSignalingState)state {
    switch (state) {
        case RTCSignalingStateStable: return @"Estável";
        case RTCSignalingStateHaveLocalOffer: return @"Oferta Local";
        case RTCSignalingStateHaveLocalPrAnswer: return @"Pré-resposta Local";
        case RTCSignalingStateHaveRemoteOffer: return @"Oferta Remota";
        case RTCSignalingStateHaveRemotePrAnswer: return @"Pré-resposta Remota";
        case RTCSignalingStateClosed: return @"Fechado";
        default: return @"Desconhecido";
    }
}

- (NSDictionary *)getConnectionStats {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    if (self.peerConnection) {
        // Valores padrão
        stats[@"connectionType"] = @"Desconhecido";
        stats[@"rtt"] = @"--";
        stats[@"packetsReceived"] = @"--";
        
        // Estado da conexão ICE
        NSString *iceState = [self iceConnectionStateToString:self.peerConnection.iceConnectionState];
        stats[@"iceState"] = iceState;
        
        // Informações sobre o formato de pixel detectado
        if (self.frameConverter.detectedPixelFormat != IOSPixelFormatUnknown) {
            stats[@"pixelFormat"] = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
            stats[@"processingMode"] = self.frameConverter.processingMode;
        }
        
        // Se a conexão estiver ativa, atualizar com valores mais precisos
        if (self.state == WebRTCManagerStateConnected) {
            stats[@"connectionType"] = self.isReceivingFrames ? @"Ativa" : @"Conectada (sem frames)";
            
            // Estimativa de RTT (round-trip time)
            if (self.isReceivingFrames) {
                stats[@"rtt"] = @"~120ms"; // Valor estimado
                stats[@"packetsReceived"] = @"Sim";
            }
        } else {
            stats[@"connectionType"] = [self stateToString:self.state];
        }
    }
    
    return stats;
}

- (float)getEstimatedFps {
    __block float estimatedFps = 0.0f;
    
    // Se não estiver recebendo frames, retornar 0
    if (!self.isReceivingFrames) {
        return 0.0f;
    }
    
    // Se não tiver conexão peer, retornar 0
    if (!self.peerConnection) {
        return 0.0f;
    }
    
    // Usar semáforo para sincronizar chamada assíncrona
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        // Procurar dados de FPS nas estatísticas
        NSDictionary<NSString *, RTCStatistics *> *stats = report.statistics;
        
        // Percorrer todas as estatísticas para procurar informações de FPS
        for (NSString *key in stats) {
            RTCStatistics *stat = stats[key];
            
            // Procurar estatísticas de track de vídeo recebido
            if ([stat.type isEqualToString:@"inbound-rtp"] &&
                [[stat.values[@"kind"] description] isEqualToString:@"video"]) {
                
                // Verificar se há valor de FPS - convertendo com segurança
                id framesPerSecondObj = stat.values[@"framesPerSecond"];
                if (framesPerSecondObj && [framesPerSecondObj isKindOfClass:[NSNumber class]]) {
                    NSNumber *framesPerSecond = (NSNumber *)framesPerSecondObj;
                    estimatedFps = [framesPerSecond floatValue];
                    writeVerboseLog(@"[WebRTCManager] FPS encontrado nas estatísticas: %.1f", estimatedFps);
                } else {
                    // Se não houver framesPerSecond, tentar calcular pelo contador de frames
                    id framesReceivedObj = stat.values[@"framesReceived"];
                    id timestampObj = stat.values[@"timestamp"];
                    
                    static NSNumber *lastFramesReceived = nil;
                    static NSNumber *lastTimestamp = nil;
                    
                    // Verificar tipos com segurança
                    if (framesReceivedObj && [framesReceivedObj isKindOfClass:[NSNumber class]] &&
                        timestampObj && [timestampObj isKindOfClass:[NSNumber class]]) {
                        
                        NSNumber *framesReceived = (NSNumber *)framesReceivedObj;
                        NSNumber *timestamp = (NSNumber *)timestampObj;
                        
                        if (lastFramesReceived && lastTimestamp) {
                            double framesDelta = [framesReceived doubleValue] - [lastFramesReceived doubleValue];
                            double timeDelta = ([timestamp doubleValue] - [lastTimestamp doubleValue]) / 1000.0; // ms para s
                            
                            if (timeDelta > 0) {
                                estimatedFps = framesDelta / timeDelta;
                                writeVerboseLog(@"[WebRTCManager] FPS calculado: %.1f (frames: %.0f, tempo: %.3fs)",
                                             estimatedFps, framesDelta, timeDelta);
                            }
                        }
                        
                        // Atualizar valores para próxima iteração
                        lastFramesReceived = framesReceived;
                        lastTimestamp = timestamp;
                    }
                }
                
                // Sair do loop assim que encontrarmos estatísticas de vídeo
                break;
            }
        }
        
        // Se não conseguimos obter FPS das estatísticas, tentar estimativa baseada na resolução
        if (estimatedFps == 0.0f && self.floatingWindow) {
            CGSize frameSize = self.floatingWindow.lastFrameSize;
            
            if (frameSize.width >= 3840) {
                // 4K geralmente funciona a 30fps
                estimatedFps = 30.0f;
            }
            else if (frameSize.width >= 1920) {
                // 1080p ou 1440p podem chegar a 60fps
                estimatedFps = 60.0f;
            }
            else {
                // Resoluções menores
                estimatedFps = 60.0f;
            }
            
            writeVerboseLog(@"[WebRTCManager] FPS estimado baseado na resolução: %.1f", estimatedFps);
        }
        
        dispatch_semaphore_signal(semaphore);
    }];
    
    // Esperar até 100ms para obter estatísticas
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    
    return estimatedFps;
}

- (void)logSdpDetails:(NSString *)sdp type:(NSString *)type {
    if (!sdp) return;
    
    writeLog(@"[WebRTCManager] Analisando %@ SDP (%lu caracteres)", type, (unsigned long)sdp.length);
    
    NSString *videoInfo = @"não detectado";
    NSString *resolutionInfo = @"desconhecida";
    NSString *fpsInfo = @"desconhecido";
    NSString *codecInfo = @"desconhecido";
    NSString *pixelFormatInfo = @"desconhecido";
    
    // Verificar se há seção de vídeo
    if ([sdp containsString:@"m=video"]) {
        videoInfo = @"presente";
        
        // Procurar informações de resolução
        NSRegularExpression *resRegex = [NSRegularExpression
                                        regularExpressionWithPattern:@"a=imageattr:.*send.*\\[x=([0-9]+)\\-?([0-9]*)?\\,y=([0-9]+)\\-?([0-9]*)?\\]"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
        
        NSArray *matches = [resRegex matchesInString:sdp
                                          options:0
                                            range:NSMakeRange(0, sdp.length)];
        
        if (matches.count > 0) {
            NSTextCheckingResult *match = matches[0];
            if (match.numberOfRanges >= 5) {
                NSString *widthStr = [sdp substringWithRange:[match rangeAtIndex:1]];
                NSString *heightStr = [sdp substringWithRange:[match rangeAtIndex:3]];
                resolutionInfo = [NSString stringWithFormat:@"%@x%@", widthStr, heightStr];
            }
        }
        
        // Procurar informações de FPS
        NSRegularExpression *fpsRegex = [NSRegularExpression
                                        regularExpressionWithPattern:@"a=framerate:([0-9]+)"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
        
        matches = [fpsRegex matchesInString:sdp
                                  options:0
                                    range:NSMakeRange(0, sdp.length)];
        
        if (matches.count > 0) {
            NSTextCheckingResult *match = matches[0];
            if (match.numberOfRanges >= 2) {
                NSString *fps = [sdp substringWithRange:[match rangeAtIndex:1]];
                fpsInfo = [NSString stringWithFormat:@"%@fps", fps];
            }
        }
        
        // Detectar codec
        if ([sdp containsString:@"H264"]) {
            codecInfo = @"H264";
        } else if ([sdp containsString:@"VP8"]) {
            codecInfo = @"VP8";
        } else if ([sdp containsString:@"VP9"]) {
            codecInfo = @"VP9";
        }
        
        // Detectar formato de pixel
        if ([sdp containsString:@"420f"]) {
            pixelFormatInfo = @"YUV 4:2:0 full-range (420f)";
        } else if ([sdp containsString:@"420v"]) {
            pixelFormatInfo = @"YUV 4:2:0 video-range (420v)";
        } else if ([sdp containsString:@"BGRA"]) {
            pixelFormatInfo = @"32-bit BGRA";
        }
    }
    
    // Verificar bitrate
    NSString *bitrateInfo = @"não especificado";
    NSRegularExpression *bitrateRegex = [NSRegularExpression
                                      regularExpressionWithPattern:@"b=AS:([0-9]+)"
                                                           options:NSRegularExpressionCaseInsensitive
                                                             error:nil];
    
    NSArray *matches = [bitrateRegex matchesInString:sdp
                                          options:0
                                            range:NSMakeRange(0, sdp.length)];
    
    if (matches.count > 0) {
        NSTextCheckingResult *match = matches[0];
        if (match.numberOfRanges >= 2) {
            NSString *bitrate = [sdp substringWithRange:[match rangeAtIndex:1]];
            bitrateInfo = [NSString stringWithFormat:@"%@kbps", bitrate];
        }
    }
    
    writeLog(@"[WebRTCManager] Detalhes do %@ SDP: vídeo=%@, codec=%@, resolução=%@, fps=%@, bitrate=%@, formato=%@",
             type, videoInfo, codecInfo, resolutionInfo, fpsInfo, bitrateInfo, pixelFormatInfo);
    
    // Verificar configurações importante para conferir compatibilidade
    if ([codecInfo isEqualToString:@"H264"]) {
        // Procurar profile-level-id para H264
        NSRegularExpression *profileRegex = [NSRegularExpression
                                          regularExpressionWithPattern:@"profile-level-id=([0-9a-fA-F]+)"
                                                               options:NSRegularExpressionCaseInsensitive
                                                                 error:nil];
        
        matches = [profileRegex matchesInString:sdp
                                     options:0
                                       range:NSMakeRange(0, sdp.length)];
        
        if (matches.count > 0) {
            NSTextCheckingResult *match = matches[0];
            if (match.numberOfRanges >= 2) {
                NSString *profile = [sdp substringWithRange:[match rangeAtIndex:1]];
                writeLog(@"[WebRTCManager] H264 profile-level-id: %@", profile);
                
                // Verificar se o perfil é compatível com iOS
                if ([profile isEqualToString:@"42e01f"] ||
                    [profile isEqualToString:@"42001f"] ||
                    [profile isEqualToString:@"640c1f"]) {
                    writeLog(@"[WebRTCManager] Perfil H264 compatível com iOS detectado");
                } else {
                    writeLog(@"[WebRTCManager] Perfil H264 não padronizado para iOS, pode causar problemas");
                }
            }
        }
    }
}

/**
 * Método para monitorar estatísticas de vídeo
 */
- (void)monitorVideoStatistics {
    // Obter a cada 2 segundos para atualizar o FPS na interface
    if (!self.peerConnection) return;
    
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        // Procurar estatísticas de vídeo inbound (track recebido)
        NSDictionary<NSString *, RTCStatistics *> *stats = report.statistics;
        
        for (NSString *key in stats) {
            RTCStatistics *stat = stats[key];
            
            if ([stat.type isEqualToString:@"inbound-rtp"] &&
                [[stat.values[@"kind"] description] isEqualToString:@"video"]) {
                
                // Extrair informações relevantes com segurança de tipo
                id framesReceivedObj = stat.values[@"framesReceived"];
                id packetsLostObj = stat.values[@"packetsLost"];
                id jitterObj = stat.values[@"jitter"];
                id bytesReceivedObj = stat.values[@"bytesReceived"];
                
                // Converter para NSNumber com verificação de tipo
                NSNumber *framesReceived = [framesReceivedObj isKindOfClass:[NSNumber class]] ? framesReceivedObj : nil;
                NSNumber *bytesReceived = [bytesReceivedObj isKindOfClass:[NSNumber class]] ? bytesReceivedObj : nil;
                
                // Calcular métricas derivadas
                static NSNumber *lastFramesReceived = nil;
                static NSNumber *lastBytesReceived = nil;
                static NSTimeInterval lastTime = 0;
                
                NSTimeInterval now = CACurrentMediaTime();
                NSTimeInterval timeDelta = now - lastTime;
                
                if (lastTime > 0 && timeDelta > 0 && lastFramesReceived && framesReceived) {
                    float frameRate = ([framesReceived floatValue] - [lastFramesReceived floatValue]) / timeDelta;
                    
                    // Atualizar FPS na floating window - verificar se a propriedade existe
                    if (self.floatingWindow && frameRate > 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.floatingWindow.currentFps = frameRate;
                            
                            // Atualizar dimensões e FPS na interface
                            if (self.floatingWindow.lastFrameSize.width > 0) {
                                // Método seguro que atualiza as informações na FloatingWindow
                                [self updateFloatingWindowInfoWithFps:frameRate];
                            }
                        });
                    }
                    
                    // Calcular bitrate atual
                    if (lastBytesReceived && bytesReceived) {
                        float bitrateMbps = ([bytesReceived doubleValue] - [lastBytesReceived doubleValue]) * 8.0 /
                                         (timeDelta * 1000000.0); // Mbps
                        
                        writeVerboseLog(@"[WebRTCManager] Estatísticas de vídeo: %.1f fps, %.2f Mbps, %.0f frames recebidos",
                                      frameRate, bitrateMbps, [framesReceived doubleValue]);
                        
                        // Se temos dados suficientes, registrar estatísticas de rede
                        // Verificar tipos com segurança
                        NSNumber *packetsLost = [packetsLostObj isKindOfClass:[NSNumber class]] ? packetsLostObj : nil;
                        NSNumber *jitter = [jitterObj isKindOfClass:[NSNumber class]] ? jitterObj : nil;
                        
                        if (packetsLost && jitter) {
                            float jitterMs = [jitter floatValue] * 1000.0; // s para ms
                            float packetLossRate = [packetsLost floatValue] / ([framesReceived floatValue] + 0.1) * 100.0; // %
                            
                            writeVerboseLog(@"[WebRTCManager] Estatísticas de rede: Jitter=%.1fms, Perda=%.1f%%",
                                          jitterMs, packetLossRate);
                        }
                    }
                }
                
                // Salvar valores para próxima iteração
                lastFramesReceived = framesReceived;
                lastBytesReceived = bytesReceived;
                lastTime = now;
                
                break; // Processar apenas o primeiro track de vídeo encontrado
            }
        }
    }];
}

- (void)startReconnectionTimer {
    // Cancelar timer existente
    [self stopReconnectionTimer];
    
    // Limitar número de tentativas de reconexão
    if (self.reconnectionAttempts >= 5) {
        writeLog(@"[WebRTCManager] Número máximo de tentativas de reconexão atingido (5)");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    self.reconnectionAttempts++;
    self.isReconnecting = YES;
    self.state = WebRTCManagerStateReconnecting;
    
    // Tentar reconectar com intervalos crescentes (backoff exponencial)
    NSTimeInterval delay = pow(2, MIN(self.reconnectionAttempts, 4)); // 2, 4, 8, 16 segundos
    
    writeLog(@"[WebRTCManager] Tentando reconexão em %.0f segundos (tentativa %d/5)",
           delay, self.reconnectionAttempts);
    
    self.reconnectionTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                             target:self
                                                           selector:@selector(attemptReconnection)
                                                           userInfo:nil
                                                            repeats:NO];
}

- (void)stopReconnectionTimer {
    if (self.reconnectionTimer) {
        [self.reconnectionTimer invalidate];
        self.reconnectionTimer = nil;
    }
}

- (void)attemptReconnection {
    [self stopReconnectionTimer];
    
    writeLog(@"[WebRTCManager] Tentando reconectar ao servidor WebRTC...");
    
    // Preservar informações do estado atual
    NSString *currentRoomId = self.roomId;
    BOOL wasReceivingFrames = self.isReceivingFrames;
    
    // Garantir limpeza completa de recursos em reconexão
    if (self.frameConverter) {
        // Limpar TODOS os recursos sem referências às variáveis não usadas
        [self.frameConverter reset];
        [self.frameConverter performSafeCleanup];
        
        // Recriar o webRTCFrameConverter se necessário
        if (self.frameConverter.frameCount > 1000) {  // Se muitos frames foram processados
            // Remover referência atual
            if (self.videoTrack) {
                [self.videoTrack removeRenderer:self.frameConverter];
            }
            
            // Criar novo conversor
            WebRTCFrameConverter *novoConversor = [[WebRTCFrameConverter alloc] init];
            
            // Transferir callback
            novoConversor.frameCallback = self.frameConverter.frameCallback;
            
            // Substituir conversor
            self.frameConverter = novoConversor;
            
            writeLog(@"[WebRTCManager] Conversor de frames recriado durante reconexão");
        }
    }
    
    // Limpar recursos sem fechar o WebRTC Manager completamente
    [self cleanupResourcesForReconnection];
    
    // Restaurar informações importantes
    self.roomId = currentRoomId;
    
    // Adicionar um pequeno delay para dar tempo aos recursos serem liberados
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Reconfigurar WebRTC
        [self configureWebRTC];
        
        // Reconectar ao WebSocket
        [self connectWebSocket];
        
        // Se estava recebendo frames, restaurar o estado visual
        if (wasReceivingFrames && self.floatingWindow) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.floatingWindow respondsToSelector:@selector(updateConnectionStatus:)]) {
                    [self.floatingWindow updateConnectionStatus:@"Reconectando..."];
                }
            });
        }
    });
}

- (void)cleanupResourcesForReconnection {
    // NOVO: Adicionar uma limpeza mais completa de todos os recursos
    
    // Fechar conexão peer anterior COM DELAY
    if (self.peerConnection) {
        // Criar uma referência local para evitar problemas de acesso após limpeza
        RTCPeerConnection *oldConnection = self.peerConnection;
        self.peerConnection = nil;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [oldConnection close];
        });
    }
    
    // Limpar track de vídeo com referência própria
    RTCVideoTrack *oldTrack = self.videoTrack;
    self.videoTrack = nil;
    
    if (oldTrack && self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
            if (videoView) {
                [oldTrack removeRenderer:videoView];
                [oldTrack removeRenderer:self.frameConverter];
            }
        });
    }
    
    // Cancelar WebSocket com referência separada
    NSURLSessionWebSocketTask *oldTask = self.webSocketTask;
    self.webSocketTask = nil;
    
    if (oldTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [oldTask cancel];
        });
    }
    
    // Liberar sessão com delay
    NSURLSession *oldSession = self.session;
    self.session = nil;
    
    if (oldSession) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [oldSession invalidateAndCancel];
        });
    }
    
    // Limpar factory
    self.factory = nil;
    
    // Limpar o conversor de frames com delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.frameConverter reset];
    });
    
    // Forçar um ciclo de liberação de memória
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool {
            NSLog(@"Liberando pool de autoreleased objects");
        }
    });
}

- (void)updateFloatingWindowInfoWithFps:(float)fps {
    if (!self.floatingWindow) return;
    
    // Gerar informações sobre o formato e taxa de frames
    NSString *formatInfo = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
    
    // Usar método conhecido da FloatingWindow para atualizar as informações
    NSString *infoText = [NSString stringWithFormat:@"%dx%d @ %.0ffps (%@)",
                         (int)self.floatingWindow.lastFrameSize.width,
                         (int)self.floatingWindow.lastFrameSize.height,
                         fps,
                         formatInfo];
    
    // Atualizar status na FloatingWindow
    [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Recebendo stream: %@", infoText]];
}

- (void)removeRendererFromVideoTrack:(id<RTCVideoRenderer>)renderer {
    if (self.videoTrack && renderer) {
        [self.videoTrack removeRenderer:renderer];
    }
}

- (void)checkResourceBalance {
    // Verificar balanceamento de recursos no frameConverter
    if (self.frameConverter) {
        NSInteger sampleBufferDiff = self.frameConverter.totalSampleBuffersCreated - self.frameConverter.totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = self.frameConverter.totalPixelBuffersLocked - self.frameConverter.totalPixelBuffersUnlocked;
        
        if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
            writeWarningLog(@"[WebRTCManager] Desbalanceamento de recursos detectado - Buffers: %ld, PixelBuffers: %ld",
                           (long)sampleBufferDiff, (long)pixelBufferDiff);
            
            // Solicitar limpeza segura
            [self.frameConverter performSafeCleanup];
        }
    }
}

#pragma mark - Sample Buffer Generation

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    // Obter o buffer usando o formato de pixel atualmente detectado
    return [self.frameConverter getLatestSampleBuffer];
}

- (CMSampleBufferRef)getLatestVideoSampleBufferWithFormat:(IOSPixelFormat)format {
    // Obter o buffer usando um formato específico
    return [self.frameConverter getLatestSampleBufferWithFormat:format];
}

- (void)setIOSCompatibilitySignaling:(BOOL)enable {
    _iosCompatibilitySignalingEnabled = enable;
    writeLog(@"[WebRTCManager] Sinalização de compatibilidade iOS %@", enable ? @"ativada" : @"desativada");
}

@end
