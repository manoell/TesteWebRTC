#import "WebRTCManager.h"

// Enum para estados de conexão
typedef NS_ENUM(int, WebRTCConnectionState) {
    WebRTCConnectionStateDisconnected = 0,
    WebRTCConnectionStateConnecting,
    WebRTCConnectionStateConnected,
    WebRTCConnectionStateError
};

@interface WebRTCManager ()

// Conexão WebRTC
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;

// WebSocket para sinalização
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;

// Buffer mais recente
@property (nonatomic, assign) CMSampleBufferRef latestSampleBuffer;

// Estado
@property (nonatomic, assign, readwrite) BOOL isReceivingFrames;
@property (nonatomic, assign, readwrite) int connectionState;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, strong) NSString *currentServerIP;

// Configurações de câmera
@property (nonatomic, assign) AVCaptureDevicePosition currentCameraPosition;
@property (nonatomic, assign) CMVideoDimensions targetResolution;
@property (nonatomic, assign) BOOL videoMirrored;
@property (nonatomic, assign) int videoOrientation;

@end

@implementation WebRTCManager

#pragma mark - Singleton

+ (instancetype)sharedInstance {
    static WebRTCManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _connectionState = WebRTCConnectionStateDisconnected;
        _isReceivingFrames = NO;
        _roomId = @"ios-camera";
        _videoMirrored = NO;
        _videoOrientation = 1; // Default para Portrait
        _currentCameraPosition = AVCaptureDevicePositionUnspecified;
        
        // Inicializar dimensões alvo com valor padrão (1080p)
        _targetResolution.width = 1920;
        _targetResolution.height = 1080;
        
        NSLog(@"[WebRTCManager] Inicializado");
    }
    return self;
}

- (void)dealloc {
    [self stopWebRTC];
    
    // Limpar buffer
    if (_latestSampleBuffer) {
        CFRelease(_latestSampleBuffer);
        _latestSampleBuffer = NULL;
    }
    
    NSLog(@"[WebRTCManager] Liberado");
}

#pragma mark - Gerenciamento de Conexão

- (void)startWebRTCWithServer:(NSString *)serverIP {
    if (self.connectionState == WebRTCConnectionStateConnected ||
        self.connectionState == WebRTCConnectionStateConnecting) {
        [self updateStatus:@"Já conectado ou conectando"];
        return;
    }
    
    self.connectionState = WebRTCConnectionStateConnecting;
    self.currentServerIP = serverIP;
    [self updateStatus:@"Conectando ao servidor"];
    
    // Configurar WebRTC
    [self setupWebRTC];
    
    // Conectar ao WebSocket
    [self connectWebSocketWithServer:serverIP];
}

- (void)stopWebRTC {
    [self updateStatus:@"Desconectando"];
    
    // Parar keep-alive timer
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    
    // Enviar mensagem "bye" para o servidor
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        [self sendMessage:@{
            @"type": @"bye",
            @"roomId": self.roomId
        }];
        
        // Pequeno delay para garantir que a mensagem seja enviada
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self cleanupResources];
        });
    } else {
        [self cleanupResources];
    }
}

- (void)cleanupResources {
    // Limpar conexão WebRTC
    if (self.peerConnection) {
        [self.peerConnection close];
        self.peerConnection = nil;
    }
    
    // Limpar WebSocket
    if (self.webSocketTask) {
        [self.webSocketTask cancel];
        self.webSocketTask = nil;
    }
    
    // Limpar sessão
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
    
    // Limpar buffer
    @synchronized(self) {
        if (self.latestSampleBuffer) {
            CFRelease(self.latestSampleBuffer);
            self.latestSampleBuffer = NULL;
        }
    }
    
    // Resetar estado
    self.videoTrack = nil;
    self.factory = nil;
    self.isReceivingFrames = NO;
    self.connectionState = WebRTCConnectionStateDisconnected;
    
    [self updateStatus:@"Desconectado"];
}

- (void)setupWebRTC {
    // Configurações para conexão WebRTC otimizadas para iOS
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    
    // Servidores STUN para NAT traversal (necessário para redes locais)
    config.iceServers = @[
        [[RTCIceServer alloc] initWithURLStrings:@[
            @"stun:stun.l.google.com:19302",
            @"stun:stun1.l.google.com:19302"
        ]]
    ];
    
    // Configurações otimizadas para redes locais
    config.iceTransportPolicy = RTCIceTransportPolicyAll;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled;
    config.candidateNetworkPolicy = RTCCandidateNetworkPolicyAll;
    
    // Inicializar a fábrica de conexões
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    
    self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                             decoderFactory:decoderFactory];
    
    // Constraints para conexão (receber apenas vídeo, sem áudio)
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                     initWithMandatoryConstraints:@{
                                         @"OfferToReceiveVideo": @"true",
                                         @"OfferToReceiveAudio": @"false"
                                     }
                                     optionalConstraints:@{
                                         @"DtlsSrtpKeyAgreement": @"true"
                                     }];
    
    // Criar a conexão Peer
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                          constraints:constraints
                                                             delegate:self];
    
    NSLog(@"[WebRTCManager] WebRTC configurado");
}

#pragma mark - WebSocket

- (void)connectWebSocketWithServer:(NSString *)serverIP {
    // Construir URL do servidor
    NSString *wsURLString = [NSString stringWithFormat:@"ws://%@:8080", serverIP];
    NSURL *wsURL = [NSURL URLWithString:wsURLString];
    
    if (!wsURL) {
        self.connectionState = WebRTCConnectionStateError;
        [self updateStatus:@"URL do servidor inválida"];
        return;
    }
    
    // Criar sessão URLSession
    self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                 delegate:self
                                            delegateQueue:[NSOperationQueue mainQueue]];
    
    // Criar tarefa WebSocket
    self.webSocketTask = [self.session webSocketTaskWithURL:wsURL];
    [self.webSocketTask resume];
    
    // Configurar recepção de mensagens
    [self receiveMessages];
    
    NSLog(@"[WebRTCManager] Conectando ao WebSocket: %@", wsURLString);
}

- (void)startKeepAliveTimer {
    // Limpar timer existente
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
    }
    
    // Criar novo timer para enviar pings a cada 5 segundos
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                           target:self
                                                         selector:@selector(sendKeepAlive)
                                                         userInfo:nil
                                                          repeats:YES];
}

- (void)sendKeepAlive {
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        // Enviar ping nativo
        [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError *error) {
            if (error) {
                NSLog(@"[WebRTCManager] Erro ao receber pong: %@", error);
            }
        }];
        
        // Enviar também mensagem de ping JSON para compatibilidade
        [self sendMessage:@{
            @"type": @"ping",
            @"roomId": self.roomId,
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000)
        }];
    }
}

- (void)receiveMessages {
    __weak typeof(self) weakSelf = self;
    
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[WebRTCManager] Erro ao receber mensagem: %@", error);
            
            if (weakSelf.webSocketTask) {
                // Tentar receber mais mensagens mesmo com erro
                [weakSelf receiveMessages];
            }
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError = nil;
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:data
                                                                     options:0
                                                                       error:&jsonError];
            
            if (jsonError) {
                NSLog(@"[WebRTCManager] Erro ao analisar mensagem JSON: %@", jsonError);
            } else {
                [weakSelf handleSignalingMessage:jsonDict];
            }
        }
        
        // Continuar recebendo mensagens
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveMessages];
        }
    }];
}

- (void)sendMessage:(NSDictionary *)message {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        NSLog(@"[WebRTCManager] WebSocket não está conectado");
        return;
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message
                                                       options:0
                                                         error:&error];
    
    if (error) {
        NSLog(@"[WebRTCManager] Erro ao serializar mensagem: %@", error);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *webSocketMessage = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
    
    [self.webSocketTask sendMessage:webSocketMessage completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[WebRTCManager] Erro ao enviar mensagem: %@", error);
        }
    }];
}

- (void)handleSignalingMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    
    if ([type isEqualToString:@"offer"]) {
        [self handleOfferMessage:message];
    }
    else if ([type isEqualToString:@"ice-candidate"]) {
        [self handleIceCandidateMessage:message];
    }
    else if ([type isEqualToString:@"pong"]) {
        // Manter a conexão viva, nada a fazer
    }
    else if ([type isEqualToString:@"ping"]) {
        // Responder com pong
        [self sendMessage:@{
            @"type": @"pong",
            @"roomId": self.roomId,
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000)
        }];
    }
    else {
        NSLog(@"[WebRTCManager] Mensagem não tratada: %@", type);
    }
}

- (void)handleOfferMessage:(NSDictionary *)message {
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        NSLog(@"[WebRTCManager] Oferta sem SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[WebRTCManager] Erro ao definir descrição remota: %@", error);
            weakSelf.connectionState = WebRTCConnectionStateError;
            [weakSelf updateStatus:@"Erro na conexão WebRTC"];
            return;
        }
        
        // Criar resposta
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                         initWithMandatoryConstraints:@{
                                             @"OfferToReceiveVideo": @"true",
                                             @"OfferToReceiveAudio": @"false"
                                         }
                                         optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints
                             completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
            if (error) {
                NSLog(@"[WebRTCManager] Erro ao criar resposta: %@", error);
                weakSelf.connectionState = WebRTCConnectionStateError;
                [weakSelf updateStatus:@"Erro ao criar resposta"];
                return;
            }
            
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    NSLog(@"[WebRTCManager] Erro ao definir descrição local: %@", error);
                    return;
                }
                
                // Enviar resposta
                [weakSelf sendMessage:@{
                    @"type": @"answer",
                    @"sdp": sdp.sdp,
                    @"roomId": weakSelf.roomId,
                    @"senderDeviceType": @"ios"
                }];
                
                NSLog(@"[WebRTCManager] Resposta enviada");
            }];
        }];
    }];
}

- (void)handleIceCandidateMessage:(NSDictionary *)message {
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) {
        NSLog(@"[WebRTCManager] Candidato ICE com dados incompletos");
        return;
    }
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                        sdpMLineIndex:[sdpMLineIndex intValue]
                                                               sdpMid:sdpMid];
    
    [self.peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[WebRTCManager] Erro ao adicionar candidato ICE: %@", error);
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    NSLog(@"[WebRTCManager] WebSocket conectado");
    
    // Enviar mensagem de join para entrar na sala
    [self sendMessage:@{
        @"type": @"join",
        @"roomId": self.roomId,
        @"deviceType": @"ios",
        @"capabilities": @{
            @"preferredPixelFormats": @[@"420f", @"420v", @"BGRA"],
            @"resolution": @{
                @"width": @(self.targetResolution.width),
                @"height": @(self.targetResolution.height)
            }
        }
    }];
    
    [self updateStatus:@"Conectado ao servidor, aguardando stream"];
    
    // Iniciar timer de keep-alive
    [self startKeepAliveTimer];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Desconhecido";
    NSLog(@"[WebRTCManager] WebSocket fechado: %@", reasonStr);
    
    // Se não foi uma desconexão explícita, tentar reconectar
    if (self.connectionState != WebRTCConnectionStateDisconnected) {
        self.connectionState = WebRTCConnectionStateError;
        [self updateStatus:@"Conexão perdida"];
        
        // Limpar recursos
        [self cleanupResources];
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    NSLog(@"[WebRTCManager] Stream adicionada: %@", stream.streamId);
    
    // Verificar se há faixas de vídeo
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        NSLog(@"[WebRTCManager] Faixa de vídeo recebida: %@", self.videoTrack.trackId);
        
        self.connectionState = WebRTCConnectionStateConnected;
        self.isReceivingFrames = YES;
        [self updateStatus:@"Recebendo stream de vídeo"];
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    NSLog(@"[WebRTCManager] Stream removida: %@", stream.streamId);
    
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        self.videoTrack = nil;
        self.isReceivingFrames = NO;
        [self updateStatus:@"Stream de vídeo interrompida"];
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    NSLog(@"[WebRTCManager] Candidato ICE gerado");
    
    // Enviar candidato para o servidor
    [self sendMessage:@{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": self.roomId
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSLog(@"[WebRTCManager] Estado ICE alterado: %ld", (long)newState);
    
    switch (newState) {
        case RTCIceConnectionStateConnected:
        case RTCIceConnectionStateCompleted:
            self.connectionState = WebRTCConnectionStateConnected;
            [self updateStatus:@"Conexão WebRTC estabelecida"];
            break;
            
        case RTCIceConnectionStateFailed:
        case RTCIceConnectionStateDisconnected:
            self.connectionState = WebRTCConnectionStateError;
            [self updateStatus:@"Problema na conexão WebRTC"];
            break;
            
        case RTCIceConnectionStateClosed:
            self.connectionState = WebRTCConnectionStateDisconnected;
            [self updateStatus:@"Conexão WebRTC fechada"];
            break;
            
        default:
            // Outros estados não alteram o estado atual
            break;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    NSLog(@"[WebRTCManager] Data channel aberto: %@", dataChannel.label);
    // Adicione implementação específica aqui se necessário
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    // Não é necessário implementar para este caso
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    // Não é necessário implementar para este caso
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {
    // Não é necessário implementar para este caso
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    // Não é necessário implementar para este caso
}

#pragma mark - Adaptação de câmera

- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position {
    self.currentCameraPosition = position;
    
    NSLog(@"[WebRTCManager] Adaptando para câmera: %@",
          position == AVCaptureDevicePositionFront ? @"frontal" : @"traseira");
}

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    _targetResolution = resolution;
    
    NSLog(@"[WebRTCManager] Definindo resolução alvo: %dx%d",
          resolution.width, resolution.height);
}

- (void)adaptOutputToVideoOrientation:(int)orientation {
    self.videoOrientation = orientation;
    
    NSLog(@"[WebRTCManager] Adaptando para orientação: %d", orientation);
}

- (void)setVideoMirrored:(BOOL)mirrored {
    _videoMirrored = mirrored;
    
    NSLog(@"[WebRTCManager] Espelhamento: %@", mirrored ? @"ativado" : @"desativado");
}

#pragma mark - Video Frames

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    if (!self.isReceivingFrames || !self.videoTrack) {
        return NULL;
    }
    
    // Para implementação simples, retornamos uma cópia do último buffer recebido
    @synchronized(self) {
        if (self.latestSampleBuffer) {
            CMSampleBufferRef result;
            CMSampleBufferCreateCopy(kCFAllocatorDefault, self.latestSampleBuffer, &result);
            return result;
        }
    }
    
    return NULL;
}

- (CMSampleBufferRef)getLatestVideoSampleBufferWithOriginalMetadata:(CMSampleBufferRef)originalBuffer {
    if (!self.isReceivingFrames || !self.videoTrack) {
        return NULL;
    }
    
    // Obter buffer de vídeo
    CMSampleBufferRef buffer = [self getLatestVideoSampleBuffer];
    
    // Se não temos buffer ou original, retornar NULL
    if (!buffer || !originalBuffer) {
        return buffer;
    }
    
    // Aplicar metadados do buffer original ao buffer WebRTC
    // Este é um placeholder - a implementação completa seria mais complexa
    // e envolveria extração e aplicação de metadados específicos da câmera
    
    return buffer;
}

#pragma mark - Utilidades

- (void)updateStatus:(NSString *)status {
    NSLog(@"[WebRTCManager] Status: %@", status);
    
    if (self.statusUpdateCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusUpdateCallback(status);
        });
    }
}

@end
