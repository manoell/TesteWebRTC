#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "WebRTCFrameConverter.h"
#import "logger.h"

@interface WebRTCManager () <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) WebRTCFrameConverter *frameConverter;
@property (nonatomic, assign) BOOL isConnected;
@end

@implementation WebRTCManager

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        self.floatingWindow = window;
        self.isConnected = NO;
        self.frameConverter = [[WebRTCFrameConverter alloc] init];
        
        // Configurar o callback do frame converter para atualizar a UI
        __weak typeof(self) weakSelf = self;
        self.frameConverter.frameCallback = ^(UIImage *image) {
            [weakSelf.floatingWindow updatePreviewImage:image];
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
}

- (void)configureWebRTC {
    writeLog(@"[WebRTCManager] Configurando WebRTC");
    
    // Configurar WebRTC
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = @[[[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]];
    
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{} optionalConstraints:@{}];
    
    self.factory = [[RTCPeerConnectionFactory alloc] init];
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config constraints:constraints delegate:self];
}

- (void)stopWebRTC {
    writeLog(@"[WebRTCManager] Parando WebRTC");
    
    self.isConnected = NO;
    
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
            writeLog(@"[WebRTCManager] Mensagem recebida: %@", json[@"type"]);
            
            NSString *type = json[@"type"];
            if ([type isEqualToString:@"offer"]) {
                [weakSelf handleOfferWithSDP:json[@"sdp"]];
            }
            else if ([type isEqualToString:@"ice-candidate"]) {
                NSString *sdp = json[@"candidate"];
                NSString *sdpMid = json[@"sdpMid"];
                NSNumber *sdpMLineIndex = json[@"sdpMLineIndex"];
                
                RTCIceCandidate *candidate = [[RTCIceCandidate alloc] initWithSdp:sdp sdpMLineIndex:[sdpMLineIndex intValue] sdpMid:sdpMid];
                [weakSelf.peerConnection addIceCandidate:candidate completionHandler:^(NSError * _Nullable error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Erro ao adicionar candidato ICE: %@", error);
                    }
                }];
            }
        }
        
        // Continuar recebendo mensagens
        [weakSelf receiveMessage];
    }];
}

- (void)handleOfferWithSDP:(NSString *)sdp {
    writeLog(@"[WebRTCManager] Recebendo oferta SDP");
    
    RTCSessionDescription *remoteSDP = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:remoteSDP completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro setRemoteDescription: %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] RemoteDescription definido com sucesso");
        
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{} optionalConstraints:@{}];
        
        [weakSelf.peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription *answer, NSError *error) {
            if (error) {
                writeLog(@"[WebRTCManager] Erro answerForConstraints: %@", error);
                return;
            }
            
            writeLog(@"[WebRTCManager] Resposta criada com sucesso");
            
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
    // Para uso futuro na substituição do feed da câmera
    return [self.frameConverter getLatestSampleBuffer];
}

#pragma mark - URLSessionWebSocketDelegate

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
        self.floatingWindow.statusLabel.text = @"Conectado";
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        writeLog(@"[WebRTCManager] WebSocket fechado com erro: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.floatingWindow.statusLabel.text = @"Desconectado - Erro";
        });
    } else {
        writeLog(@"[WebRTCManager] WebSocket fechado normalmente");
    }
}

#pragma mark - Simulação

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
    
    if (!self.isConnected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updatePreviewImage:image];
        });
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream adicionado com %lu video tracks e %lu audio tracks",
             (unsigned long)stream.videoTracks.count,
             (unsigned long)stream.audioTracks.count);
    
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.floatingWindow.statusLabel.text = @"Stream recebido";
            
            // Parar o timer de simulação quando receber um stream real
            if (self.frameTimer) {
                [self.frameTimer invalidate];
                self.frameTimer = nil;
            }
            
            // Conectar o video track ao renderer
            [self.videoTrack addRenderer:self.frameConverter];
            self.isConnected = YES;
            
            writeLog(@"[WebRTCManager] Renderer conectado ao video track");
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
        self.floatingWindow.statusLabel.text = @"Stream removido";
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    NSString *state = @"Desconhecido";
    switch (stateChanged) {
        case RTCSignalingStateStable:
            state = @"Stable";
            break;
        case RTCSignalingStateHaveLocalOffer:
            state = @"HaveLocalOffer";
            break;
        case RTCSignalingStateHaveLocalPrAnswer:
            state = @"HaveLocalPrAnswer";
            break;
        case RTCSignalingStateHaveRemoteOffer:
            state = @"HaveRemoteOffer";
            break;
        case RTCSignalingStateHaveRemotePrAnswer:
            state = @"HaveRemotePrAnswer";
            break;
        case RTCSignalingStateClosed:
            state = @"Closed";
            break;
    }
    writeLog(@"[WebRTCManager] Estado de sinalização mudou para: %@", state);
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Negociação necessária");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *state = @"Desconhecido";
    switch (newState) {
        case RTCIceConnectionStateNew:
            state = @"New";
            break;
        case RTCIceConnectionStateChecking:
            state = @"Checking";
            break;
        case RTCIceConnectionStateConnected:
            state = @"Connected";
            break;
        case RTCIceConnectionStateCompleted:
            state = @"Completed";
            break;
        case RTCIceConnectionStateFailed:
            state = @"Failed";
            break;
        case RTCIceConnectionStateDisconnected:
            state = @"Disconnected";
            break;
        case RTCIceConnectionStateClosed:
            state = @"Closed";
            break;
        case RTCIceConnectionStateCount:
            state = @"Count";
            break;
    }
    writeLog(@"[WebRTCManager] Estado da conexão ICE mudou para: %@", state);
    
    if (newState == RTCIceConnectionStateConnected || newState == RTCIceConnectionStateCompleted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.floatingWindow.statusLabel.text = @"Stream conectado";
        });
    } else if (newState == RTCIceConnectionStateFailed || newState == RTCIceConnectionStateDisconnected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.floatingWindow.statusLabel.text = @"Problema na conexão";
            self.isConnected = NO;
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

@end
