#import "WebRTCManager.h"
#import "Logger.h"

@interface WebRTCManager ()
@property (nonatomic, strong) NSString *serverIP;
@property (nonatomic, assign, readwrite) BOOL isReceivingFrames;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) RTCCVPixelBuffer *lastFrame;
@end

@implementation WebRTCManager

- (instancetype)initWithServerIP:(NSString *)serverIP {
    self = [super init];
    if (self) {
        _serverIP = serverIP;
        _isReceivingFrames = NO;
        _roomId = @"ios-camera";
        writeLog(@"WebRTCManager inicializado com servidor: %@", serverIP);
    }
    return self;
}

- (void)startWebRTC {
    if (_peerConnection) {
        writeLog(@"Conexão WebRTC já ativa");
        return;
    }
    
    writeLog(@"Iniciando conexão WebRTC com servidor: %@", _serverIP);
    
    // Configurar WebRTC
    [self setupWebRTC];
    
    // Conectar WebSocket
    [self connectWebSocket];
}

- (void)stopWebRTC {
    writeLog(@"Parando conexão WebRTC");
    
    // Enviar mensagem de bye ao servidor
    if (_webSocketTask) {
        NSDictionary *byeMessage = @{@"type": @"bye", @"roomId": _roomId};
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:byeMessage options:0 error:nil];
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        
        [_webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                  completionHandler:^(NSError * _Nullable error) {
            if (error) {
                writeLog(@"Erro ao enviar mensagem 'bye': %@", error);
            }
        }];
    }
    
    // Fechar conexão peer
    if (_peerConnection) {
        [_peerConnection close];
        _peerConnection = nil;
    }
    
    // Limpar video track
    _videoTrack = nil;
    
    // Cancelar WebSocket
    if (_webSocketTask) {
        [_webSocketTask cancel];
        _webSocketTask = nil;
    }
    
    // Limpar factory
    _factory = nil;
    
    // Reset estado
    _isReceivingFrames = NO;
    
    writeLog(@"Conexão WebRTC finalizada");
}

- (void)setupWebRTC {
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
    
    writeLog(@"WebRTC configurado");
}

- (void)connectWebSocket {
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", _serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    
    _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                             delegate:self
                                        delegateQueue:[NSOperationQueue mainQueue]];
    
    _webSocketTask = [_session webSocketTaskWithURL:url];
    [_webSocketTask resume];
    
    writeLog(@"Conectando ao WebSocket: %@", urlString);
    
    // Configurar recepção de mensagens
    [self receiveMessage];
}

- (void)receiveMessage {
    __weak typeof(self) weakSelf = self;
    
    [_webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message,
                                                         NSError * _Nullable error) {
        if (error) {
            writeLog(@"Erro ao receber mensagem: %@", error);
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *jsonData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                     options:0
                                                                       error:nil];
            
            NSString *type = jsonDict[@"type"];
            if ([type isEqualToString:@"offer"]) {
                [weakSelf handleOfferMessage:jsonDict];
            } else if ([type isEqualToString:@"ice-candidate"]) {
                [weakSelf handleCandidateMessage:jsonDict];
            }
        }
        
        // Continue recebendo mensagens
        if (weakSelf.webSocketTask) {
            [weakSelf receiveMessage];
        }
    }];
}

- (void)sendJoinMessage {
    if (!_webSocketTask) return;
    
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
            writeLog(@"Erro ao enviar mensagem JOIN: %@", error);
        }
    }];
    
    writeLog(@"Enviada mensagem JOIN para sala: %@", _roomId);
}

- (void)handleOfferMessage:(NSDictionary *)message {
    NSString *sdp = message[@"sdp"];
    if (!sdp) return;
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [_peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"Erro ao definir descrição remota: %@", error);
            return;
        }
        
        // Criar resposta
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
            initWithMandatoryConstraints:@{@"OfferToReceiveVideo": @"true", @"OfferToReceiveAudio": @"false"}
            optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription * _Nullable sdp,
                                                                                    NSError * _Nullable error) {
            if (error) {
                writeLog(@"Erro ao criar resposta: %@", error);
                return;
            }
            
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"Erro ao definir descrição local: %@", error);
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
                                            writeLog(@"Erro ao enviar resposta: %@", error);
                                        }
                                    }];
            }];
        }];
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) return;
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                         sdpMLineIndex:[sdpMLineIndex intValue]
                                                                sdpMid:sdpMid];
    
    [_peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"Erro ao adicionar candidato ICE: %@", error);
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
   didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"WebSocket conectado");
    
    // Enviar JOIN
    [self sendJoinMessage];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
   didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    writeLog(@"WebSocket fechado");
    
    _webSocketTask = nil;
    _isReceivingFrames = NO;
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    if (stream.videoTracks.count > 0) {
        _videoTrack = stream.videoTracks[0];
        writeLog(@"Stream de vídeo recebida");
        
        // Configurar recepção de frames
        [_videoTrack addRenderer:(id<RTCVideoRenderer>)self];
        _isReceivingFrames = YES;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    if (!_webSocketTask) return;
    
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
                           writeLog(@"Erro ao enviar candidato ICE: %@", error);
                       }
                   }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    if (newState == RTCIceConnectionStateConnected || newState == RTCIceConnectionStateCompleted) {
        writeLog(@"Conexão ICE estabelecida");
    } else if (newState == RTCIceConnectionStateFailed || newState == RTCIceConnectionStateDisconnected) {
        writeLog(@"Conexão ICE perdida");
        _isReceivingFrames = NO;
    }
}

// Implementações obrigatórias (vazias)
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}

#pragma mark - RTCVideoRenderer (para receber frames)

- (void)setSize:(CGSize)size {
    // Apenas para conformidade com o protocolo
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (!frame) return;
    
    // Armazenar último frame recebido
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        _lastFrame = (RTCCVPixelBuffer *)frame.buffer;
    }
}

#pragma mark - Obtenção de frames

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    if (!_lastFrame || !_lastFrame.pixelBuffer) {
        return NULL;
    }
    
    // Criar descrição do formato
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, _lastFrame.pixelBuffer, &formatDescription);
    
    if (status != 0) {
        return NULL;
    }
    
    // Criar timing info
    CMSampleTimingInfo timingInfo = {0};
    timingInfo.duration = CMTimeMake(1, 30); // 30fps
    timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    timingInfo.decodeTimeStamp = kCMTimeInvalid;
    
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
        return NULL;
    }
    
    return sampleBuffer;
}

@end
