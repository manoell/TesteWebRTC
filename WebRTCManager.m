#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "WebRTCFrameConverter.h"
#import "logger.h"

@interface WebRTCManager ()
@property (nonatomic, assign) BOOL isReceivingFrames;
@end

@implementation WebRTCManager

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        self.floatingWindow = window;
        self.isConnected = NO;
        self.isReceivingFrames = NO;
        self.frameConverter = [[WebRTCFrameConverter alloc] init];
        
        // Configurar o callback do frame converter para atualizar a UI
        __weak typeof(self) weakSelf = self;
        self.frameConverter.frameCallback = ^(UIImage *image) {
            [weakSelf.floatingWindow updatePreviewImage:image];
            weakSelf.isReceivingFrames = YES;
        };
        
        writeLog(@"[WebRTCManager] WebRTCManager inicializado");
    }
    return self;
}

- (void)startWebRTC {
    [self configureWebRTC];
    [self connectWebSocket];
    
    // Para depuração - mostrar uma imagem de teste enquanto aguarda conexão
    [self captureAndSendTestImage];
    
    // Iniciar um timer para mostrar imagens de teste durante a conexão
    self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(captureAndSendTestImage)
                                                    userInfo:nil
                                                     repeats:YES];
    
    // Verificar status após 10 segundos
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self checkWebRTCStatus];
    });
}

- (void)configureWebRTC {
    writeLog(@"[WebRTCManager] Configurando WebRTC");
    
    // Configurar WebRTC
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = @[[[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]];
    
    // Configurações específicas para receber vídeo
    NSDictionary *mandatoryConstraints = @{
        @"OfferToReceiveVideo": @"true",
        @"OfferToReceiveAudio": @"false"
    };
    
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                      initWithMandatoryConstraints:mandatoryConstraints
                                      optionalConstraints:nil];
    
    // Verificar se o factory pode ser criado com encoder/decoder
    if ([RTCPeerConnectionFactory instancesRespondToSelector:@selector(initWithEncoderFactory:decoderFactory:)]) {
        RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        
        self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                 decoderFactory:decoderFactory];
    } else {
        self.factory = [[RTCPeerConnectionFactory alloc] init];
    }
    
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                           constraints:constraints
                                                              delegate:self];
    
    writeLog(@"[WebRTCManager] WebRTC configurado com suporte a vídeo");
}

- (void)stopWebRTC {
    writeLog(@"[WebRTCManager] Parando WebRTC");
    
    self.isConnected = NO;
    self.isReceivingFrames = NO;
    
    if (self.frameTimer) {
        [self.frameTimer invalidate];
        self.frameTimer = nil;
    }
    
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self.frameConverter];
        self.videoTrack = nil;
    }
    
    [self.webSocketTask cancel];
    self.webSocketTask = nil;
    
    [self.peerConnection close];
    self.peerConnection = nil;
}

- (void)connectWebSocket {
    writeLog(@"[WebRTCManager] Conectando ao WebSocket");
    
    NSURL *url = [NSURL URLWithString:@"ws://192.168.0.178:8080"];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    self.webSocketTask = [self.session webSocketTaskWithRequest:request];
    [self.webSocketTask resume];
    
    [self receiveMessage];
}

- (void)receiveMessage {
    if (!self.webSocketTask) return;
    
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] WebSocket erro: %@", error);
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            
            NSString *type = json[@"type"];
            writeLog(@"[WebRTCManager] Mensagem recebida: %@", type);
            
            // Vamos imprimir mais detalhes sobre a oferta SDP para depuração
            if ([type isEqualToString:@"offer"]) {
                NSString *sdp = json[@"sdp"];
                writeLog(@"[WebRTCManager] Oferta SDP recebida, primeiros 100 chars: %@",
                         [sdp substringToIndex:MIN(100, sdp.length)]);
                
                // Verificar se a oferta contém audio e video
                BOOL hasAudio = [sdp containsString:@"m=audio"];
                BOOL hasVideo = [sdp containsString:@"m=video"];
                writeLog(@"[WebRTCManager] A oferta contém audio: %@, video: %@",
                         hasAudio ? @"Sim" : @"Não",
                         hasVideo ? @"Sim" : @"Não");
                
                [weakSelf handleOfferWithSDP:sdp];
            }
            else if ([type isEqualToString:@"ice-candidate"]) {
                NSString *sdp = json[@"candidate"];
                NSString *sdpMid = json[@"sdpMid"];
                NSNumber *sdpMLineIndex = json[@"sdpMLineIndex"];
                
                RTCIceCandidate *candidate = [[RTCIceCandidate alloc] initWithSdp:sdp sdpMLineIndex:[sdpMLineIndex intValue] sdpMid:sdpMid];
                writeLog(@"[WebRTCManager] Adicionando candidato ICE: %@, mid: %@",
                         [sdp substringToIndex:MIN(50, sdp.length)], sdpMid);
                
                [weakSelf.peerConnection addIceCandidate:candidate completionHandler:^(NSError * _Nullable error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Erro ao adicionar candidato ICE: %@", error);
                    } else {
                        writeLog(@"[WebRTCManager] Candidato ICE adicionado com sucesso");
                    }
                }];
            }
        }
        
        // Continuar recebendo mensagens
        [weakSelf receiveMessage];
    }];
}

- (void)handleOfferWithSDP:(NSString *)sdp {
    writeLog(@"[WebRTCManager] Analisando oferta SDP...");
    
    // Verificar se a SDP contém mídia de vídeo
    NSArray *lines = [sdp componentsSeparatedByString:@"\n"];
    BOOL hasVideoMedia = NO;
    BOOL hasVideoCodec = NO;
    
    for (NSString *line in lines) {
        if ([line hasPrefix:@"m=video"]) {
            hasVideoMedia = YES;
            writeLog(@"[WebRTCManager] Linha de mídia de vídeo encontrada: %@", line);
        }
        if (hasVideoMedia && [line hasPrefix:@"a=rtpmap:"] &&
            ([line containsString:@"H264"] || [line containsString:@"VP8"] || [line containsString:@"VP9"])) {
            hasVideoCodec = YES;
            writeLog(@"[WebRTCManager] Codec de vídeo encontrado: %@", line);
        }
    }
    
    if (!hasVideoMedia) {
        writeLog(@"[WebRTCManager] AVISO: A oferta SDP não contém mídia de vídeo!");
    }
    
    if (!hasVideoCodec) {
        writeLog(@"[WebRTCManager] AVISO: Nenhum codec de vídeo conhecido encontrado na oferta!");
    }
    
    // Continuar com o processamento normal da oferta
    RTCSessionDescription *remoteSDP = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:remoteSDP completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro setRemoteDescription: %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] RemoteDescription definido com sucesso");
        
        // Configurações específicas para a resposta
        NSDictionary *mandatoryConstraints = @{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        };
        
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                          initWithMandatoryConstraints:mandatoryConstraints
                                          optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription *answer, NSError *error) {
            if (error) {
                writeLog(@"[WebRTCManager] Erro answerForConstraints: %@", error);
                return;
            }
            
            writeLog(@"[WebRTCManager] Resposta SDP criada com sucesso");
            
            // Analisar a resposta SDP gerada
            NSString *answerSdp = answer.sdp;
            BOOL responseHasVideo = [answerSdp containsString:@"m=video"];
            writeLog(@"[WebRTCManager] A resposta SDP contém vídeo: %@",
                    responseHasVideo ? @"Sim" : @"Não");
            
            [weakSelf.peerConnection setLocalDescription:answer completionHandler:^(NSError *error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro setLocalDescription: %@", error);
                    return;
                }
                
                writeLog(@"[WebRTCManager] LocalDescription definido com sucesso");
                
                NSDictionary *response = @{
                    @"type": @"answer",
                    @"sdp": answer.sdp
                };
                
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                
                NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
                [weakSelf.webSocketTask sendMessage:message completionHandler:^(NSError *error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Erro ao enviar resposta: %@", error);
                    } else {
                        writeLog(@"[WebRTCManager] Resposta enviada com sucesso");
                    }
                }];
            }];
        }];
    }];
}

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    return [self.frameConverter getLatestSampleBuffer];
}

- (void)captureAndSendTestImage {
    // Para testes - enviar uma imagem gerada para a visualização
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(320, 240), YES, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Fundo preto
    CGContextSetFillColorWithColor(context, [UIColor blackColor].CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, 320, 240));
    
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
    
    // Desenhar um círculo colorido que muda
    static float hue = 0.0;
    UIColor *color = [UIColor colorWithHue:hue saturation:1.0 brightness:1.0 alpha:1.0];
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(135, 40, 50, 50));
    hue += 0.05;
    if (hue > 1.0) hue = 0.0;
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if (!self.isConnected || !self.isReceivingFrames) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updatePreviewImage:image];
        });
    }
}

- (void)checkWebRTCStatus {
    writeLog(@"[WebRTCManager] Verificando status WebRTC:");
    writeLog(@"  - PeerConnection: %@", self.peerConnection ? @"Inicializado" : @"NULL");
    writeLog(@"  - VideoTrack: %@", self.videoTrack ? @"Recebido" : @"NULL");
    writeLog(@"  - IsConnected: %@", self.isConnected ? @"Sim" : @"Não");
    writeLog(@"  - IsReceivingFrames: %@", self.isReceivingFrames ? @"Sim" : @"Não");
    writeLog(@"  - ICE Connection State: %@", [self iceConnectionStateToString:self.peerConnection.iceConnectionState]);
    writeLog(@"  - Signaling State: %@", [self signalingStateToString:self.peerConnection.signalingState]);
    
    // Se não estiver conectado, mostre uma mensagem de status apropriada
    if (!self.isConnected || !self.videoTrack) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Sem conexão WebRTC"];
        });
    }
}

- (NSString *)iceConnectionStateToString:(RTCIceConnectionState)state {
    switch (state) {
        case RTCIceConnectionStateNew: return @"New";
        case RTCIceConnectionStateChecking: return @"Checking";
        case RTCIceConnectionStateConnected: return @"Connected";
        case RTCIceConnectionStateCompleted: return @"Completed";
        case RTCIceConnectionStateFailed: return @"Failed";
        case RTCIceConnectionStateDisconnected: return @"Disconnected";
        case RTCIceConnectionStateClosed: return @"Closed";
        case RTCIceConnectionStateCount: return @"Count";
        default: return @"Unknown";
    }
}

- (NSString *)signalingStateToString:(RTCSignalingState)state {
    switch (state) {
        case RTCSignalingStateStable: return @"Stable";
        case RTCSignalingStateHaveLocalOffer: return @"HaveLocalOffer";
        case RTCSignalingStateHaveLocalPrAnswer: return @"HaveLocalPrAnswer";
        case RTCSignalingStateHaveRemoteOffer: return @"HaveRemoteOffer";
        case RTCSignalingStateHaveRemotePrAnswer: return @"HaveRemotePrAnswer";
        case RTCSignalingStateClosed: return @"Closed";
        default: return @"Unknown";
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream adicionado com %lu video tracks e %lu audio tracks",
             (unsigned long)stream.videoTracks.count,
             (unsigned long)stream.audioTracks.count);
    
    // Logs detalhados dos video tracks
    for (RTCVideoTrack *track in stream.videoTracks) {
        writeLog(@"[WebRTCManager] Video track encontrado: ID=%@, habilitado=%@",
                track.trackId,
                track.isEnabled ? @"Sim" : @"Não");
    }
    
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Stream recebido"];
            
            // Parar o timer de simulação quando receber um stream real
            if (self.frameTimer) {
                [self.frameTimer invalidate];
                self.frameTimer = nil;
            }
            
            // Conectar o video track ao renderer
            [self.videoTrack addRenderer:self.frameConverter];
            self.isConnected = YES;
            
            writeLog(@"[WebRTCManager] Renderer conectado ao video track");
            
            // Verificar se estamos recebendo frames após um tempo
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.frameConverter.isReceivingFrames) {
                    writeLog(@"[WebRTCManager] Confirmado: recebendo frames de vídeo");
                    [self.floatingWindow updateConnectionStatus:@"Stream ativo"];
                } else {
                    writeLog(@"[WebRTCManager] ALERTA: Não confirmado recebimento de frames após 3 segundos");
                    [self.floatingWindow updateConnectionStatus:@"Sem frames de vídeo"];
                }
            });
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream removido");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.videoTrack) {
            [self.videoTrack removeRenderer:self.frameConverter];
            self.videoTrack = nil;
        }
        self.isConnected = NO;
        self.isReceivingFrames = NO;
        [self.floatingWindow updateConnectionStatus:@"Stream removido"];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    NSString *state = [self signalingStateToString:stateChanged];
    writeLog(@"[WebRTCManager] Estado de sinalização mudou para: %@", state);
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Negociação necessária");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *state = [self iceConnectionStateToString:newState];
    writeLog(@"[WebRTCManager] Estado da conexão ICE mudou para: %@", state);
    
    if (newState == RTCIceConnectionStateConnected || newState == RTCIceConnectionStateCompleted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"ICE Conectado"];
        });
    } else if (newState == RTCIceConnectionStateFailed || newState == RTCIceConnectionStateDisconnected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Problema na conexão"];
            self.isConnected = NO;
            self.isReceivingFrames = NO;
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    NSString *state = @"Desconhecido";
    switch (newState) {
        case RTCIceGatheringStateNew:
            state = @"New";
            break;
        case RTCIceGatheringStateGathering:
            state = @"Gathering";
            break;
        case RTCIceGatheringStateComplete:
            state = @"Complete";
            break;
    }
    writeLog(@"[WebRTCManager] Estado de coleta ICE mudou para: %@", state);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Candidato ICE gerado: %@", candidate.sdp);
    
    NSDictionary *iceCandidateDict = @{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex)
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:iceCandidateDict options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
    [self.webSocketTask sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao enviar candidato ICE: %@", error);
        }
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    writeLog(@"[WebRTCManager] Candidatos ICE removidos: %lu", (unsigned long)candidates.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    writeLog(@"[WebRTCManager] Canal de dados aberto: %@", dataChannel.label);
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCManager] WebSocket aberto");
    
    NSDictionary *joinMsg = @{@"type": @"join", @"roomId": @"ios-camera"};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:joinMsg options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
    [webSocketTask sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao enviar mensagem de join: %@", error);
        } else {
            writeLog(@"[WebRTCManager] Mensagem de join enviada");
        }
    }];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:@"WebSocket Conectado"];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        writeLog(@"[WebRTCManager] WebSocket fechado com erro: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Desconectado - Erro"];
        });
    } else {
        writeLog(@"[WebRTCManager] WebSocket fechado normalmente");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Desconectado"];
        });
    }
    
    // Resetar o estado de conexão
    self.isConnected = NO;
    self.isReceivingFrames = NO;
}

@end
