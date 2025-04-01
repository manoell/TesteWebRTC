#import "WebRTCManager.h"
#import "Logger.h"

@interface WebRTCManager ()
@property (nonatomic, assign, readwrite) BOOL isReceivingFrames;
@property (nonatomic, assign, readwrite) BOOL active;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) RTCCVPixelBuffer *lastFrame;
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@end

@implementation WebRTCManager

// Implementação Singleton
+ (instancetype)sharedInstance {
    static WebRTCManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverIP = @"192.168.0.178"; // IP padrão
        _isReceivingFrames = NO;
        _roomId = @"ios-camera";
        _processingQueue = dispatch_queue_create("com.vcam.webrtc.processing", DISPATCH_QUEUE_SERIAL);
        _active = NO;
        vcam_logf(@"WebRTCManager inicializado com servidor: %@", _serverIP);
    }
    return self;
}

- (void)startWebRTC {
    if (_active) {
        vcam_log(@"WebRTC já está ativo");
        return;
    }
    
    vcam_logf(@"Iniciando WebRTC com servidor: %@", _serverIP);
    _active = YES;
    
    dispatch_async(_processingQueue, ^{
        [self setupWebRTC];
        [self connectWebSocket];
    });
}

- (void)stopWebRTC {
    if (!_active) {
        return;
    }
    
    vcam_log(@"Parando WebRTC");
    _active = NO;
    _isReceivingFrames = NO;
    
    // Enviar mensagem de bye ao servidor
    if (_webSocketTask) {
        NSDictionary *byeMessage = @{@"type": @"bye", @"roomId": _roomId};
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:byeMessage options:0 error:nil];
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        
        [_webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                completionHandler:^(NSError * _Nullable error) {
            if (error) {
                vcam_logf(@"Erro ao enviar bye: %@", error);
            }
        }];
    }
    
    dispatch_async(_processingQueue, ^{
        // Limpar video track
        if (self.videoTrack) {
            [self.videoTrack removeRenderer:(id<RTCVideoRenderer>)self];
            self.videoTrack = nil;
        }
        
        // Fechar conexão peer
        if (self.peerConnection) {
            [self.peerConnection close];
            self.peerConnection = nil;
        }
        
        // Cancelar WebSocket
        if (self.webSocketTask) {
            [self.webSocketTask cancel];
            self.webSocketTask = nil;
        }
        
        // Limpar factory
        self.factory = nil;
        
        // Limpar frame
        self.lastFrame = nil;
        
        vcam_log(@"WebRTC desativado com sucesso");
    });
}

- (void)setupWebRTC {
    vcam_log(@"Configurando WebRTC");
    
    // Configuração para rede local
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = @[
        [[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]
    ];
    
    // Configurações básicas
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
        initWithMandatoryConstraints:@{@"OfferToReceiveVideo": @"true", @"OfferToReceiveAudio": @"false"}
        optionalConstraints:nil];
    
    // Criar factory e peer connection
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    
    _factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                       decoderFactory:decoderFactory];
    
    _peerConnection = [_factory peerConnectionWithConfiguration:config
                                                  constraints:constraints
                                                     delegate:self];
    
    vcam_log(@"WebRTC configurado com sucesso");
}

- (void)connectWebSocket {
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", _serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        vcam_log(@"URL inválida para WebSocket");
        return;
    }
    
    _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                           delegate:self
                                      delegateQueue:[NSOperationQueue mainQueue]];
    
    _webSocketTask = [_session webSocketTaskWithURL:url];
    [_webSocketTask resume];
    
    vcam_logf(@"Conectando ao WebSocket: %@", urlString);
    
    // Configurar recepção de mensagens
    [self receiveMessage];
}

- (void)receiveMessage {
    if (!_webSocketTask || !_active) return;
    
    __weak typeof(self) weakSelf = self;
    
    [_webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message,
                                                       NSError * _Nullable error) {
        if (error) {
            vcam_logf(@"Erro ao receber mensagem: %@", error);
            
            // Tentar reconexão em caso de erro, se ainda ativo
            if (weakSelf.active) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf connectWebSocket];
                });
            }
            return;
        }
        
        if (!weakSelf.active) return;
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *jsonData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError = nil;
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                   options:0
                                                                     error:&jsonError];
            
            if (jsonError) {
                vcam_logf(@"Erro ao processar JSON: %@", jsonError);
                return;
            }
            
            NSString *type = jsonDict[@"type"];
            if ([type isEqualToString:@"offer"]) {
                [weakSelf handleOfferMessage:jsonDict];
            } else if ([type isEqualToString:@"ice-candidate"]) {
                [weakSelf handleCandidateMessage:jsonDict];
            }
        }
        
        // Continue recebendo mensagens se ainda estiver ativo
        if (weakSelf.active && weakSelf.webSocketTask) {
            [weakSelf receiveMessage];
        }
    }];
}

- (void)sendJoinMessage {
    if (!_webSocketTask || !_active) return;
    
    NSDictionary *joinMessage = @{
        @"type": @"join",
        @"roomId": _roomId,
        @"deviceType": @"ios"
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:joinMessage options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    [_webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
              completionHandler:^(NSError * _Nullable error) {
        if (error) {
            vcam_logf(@"Erro ao enviar mensagem JOIN: %@", error);
        }
    }];
    
    vcam_logf(@"Enviada mensagem JOIN para sala: %@", _roomId);
}

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!_peerConnection || !_active) return;
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) return;
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [_peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            vcam_logf(@"Erro ao definir descrição remota: %@", error);
            return;
        }
        
        // Criar resposta
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
            initWithMandatoryConstraints:@{@"OfferToReceiveVideo": @"true", @"OfferToReceiveAudio": @"false"}
            optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription * _Nullable sdp,
                                                                                  NSError * _Nullable error) {
            if (error) {
                vcam_logf(@"Erro ao criar resposta: %@", error);
                return;
            }
            
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    vcam_logf(@"Erro ao definir descrição local: %@", error);
                    return;
                }
                
                // Enviar resposta
                NSDictionary *answerMessage = @{
                    @"type": @"answer",
                    @"sdp": sdp.sdp,
                    @"roomId": weakSelf.roomId
                };
                
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:answerMessage options:0 error:nil];
                NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                
                [weakSelf.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                                  completionHandler:^(NSError * _Nullable error) {
                    if (error) {
                        vcam_logf(@"Erro ao enviar resposta: %@", error);
                    }
                }];
            }];
        }];
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    if (!_peerConnection || !_active) return;
    
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) return;
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                       sdpMLineIndex:[sdpMLineIndex intValue]
                                                              sdpMid:sdpMid];
    
    [_peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            vcam_logf(@"Erro ao adicionar candidato ICE: %@", error);
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(NSString *)protocol {
    vcam_log(@"WebSocket conectado com sucesso");
    
    // Enviar JOIN
    [self sendJoinMessage];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    vcam_log(@"WebSocket fechado");
    
    NSString *reasonStr = reason ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"Desconhecido";
    vcam_logf(@"Razão do fechamento: %@", reasonStr);
    
    _webSocketTask = nil;
    _isReceivingFrames = NO;
    
    // Tentar reconectar se ainda estiver ativo
    if (_active) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self connectWebSocket];
        });
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    if (!_active) return;
    
    vcam_logf(@"Stream adicionada: %@ (áudio: %lu, vídeo: %lu)",
            stream.streamId, (unsigned long)stream.audioTracks.count, (unsigned long)stream.videoTracks.count);
    
    if (stream.videoTracks.count > 0) {
        _videoTrack = stream.videoTracks[0];
        vcam_logf(@"Faixa de vídeo recebida: %@", _videoTrack.trackId);
        
        // Adicionar self como renderer para receber frames
        [_videoTrack addRenderer:(id<RTCVideoRenderer>)self];
        _isReceivingFrames = YES;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    if (!_webSocketTask || !_active) return;
    
    NSDictionary *message = @{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": _roomId
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    [_webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                 completionHandler:^(NSError * _Nullable error) {
        if (error) {
            vcam_logf(@"Erro ao enviar candidato ICE: %@", error);
        }
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *stateString = @"Desconhecido";
    switch (newState) {
        case RTCIceConnectionStateNew: stateString = @"Novo"; break;
        case RTCIceConnectionStateChecking: stateString = @"Verificando"; break;
        case RTCIceConnectionStateConnected: stateString = @"Conectado"; break;
        case RTCIceConnectionStateCompleted: stateString = @"Completo"; break;
        case RTCIceConnectionStateFailed: stateString = @"Falha"; break;
        case RTCIceConnectionStateDisconnected: stateString = @"Desconectado"; break;
        case RTCIceConnectionStateClosed: stateString = @"Fechado"; break;
        default: break;
    }
    
    vcam_logf(@"Estado da conexão ICE alterado: %@", stateString);
    
    if (newState == RTCIceConnectionStateConnected || newState == RTCIceConnectionStateCompleted) {
        vcam_log(@"Conexão WebRTC estabelecida com sucesso");
    } else if (newState == RTCIceConnectionStateFailed || newState == RTCIceConnectionStateDisconnected) {
        vcam_log(@"Conexão WebRTC perdida, irá tentar reconectar");
        _isReceivingFrames = NO;
        
        // Tentar reconectar se ainda estiver ativo
        if (_active) {
            [self stopWebRTC];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self startWebRTC];
            });
        }
    }
}

// Implementações obrigatórias (vazias)
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
    vcam_logf(@"WebRTC: Tamanho do frame definido para %@", NSStringFromCGSize(size));
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (!_active) return;
    
    // Armazenar último frame recebido
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        _lastFrame = (RTCCVPixelBuffer *)frame.buffer;
        _isReceivingFrames = YES;
    }
}

#pragma mark - Obtenção de frames

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    if (!_lastFrame || !_lastFrame.pixelBuffer || !_active || !_isReceivingFrames) {
        return NULL;
    }
    
    // Criar descrição do formato
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, _lastFrame.pixelBuffer, &formatDescription);
    
    if (status != 0) {
        vcam_logf(@"Erro ao criar descrição de formato: %d", (int)status);
        return NULL;
    }
    
    // Criar timing info
    CMSampleTimingInfo timingInfo = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    // Criar sample buffer
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        _lastFrame.pixelBuffer,
        true,
        NULL,
        NULL,
        formatDescription,
        &timingInfo,
        &sampleBuffer
    );
    
    // Liberar a descrição do formato
    CFRelease(formatDescription);
    
    if (status != 0) {
        vcam_logf(@"Erro ao criar sample buffer: %d", (int)status);
        return NULL;
    }
    
    return sampleBuffer;
}

- (BOOL)isConnected {
    return _active && _isReceivingFrames && _peerConnection &&
           (_peerConnection.iceConnectionState == RTCIceConnectionStateConnected ||
            _peerConnection.iceConnectionState == RTCIceConnectionStateCompleted);
}

@end
