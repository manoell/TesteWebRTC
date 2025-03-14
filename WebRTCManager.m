#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "logger.h"

@interface WebRTCManager () <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation WebRTCManager

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        self.floatingWindow = window;
    }
    return self;
}

- (void)startWebRTC {
    // Configurar WebRTC
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = @[[[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]];
    
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{} optionalConstraints:@{}];
    
    self.factory = [[RTCPeerConnectionFactory alloc] init];
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config constraints:constraints delegate:self];
    
    // Conectar ao servidor WebSocket
    [self connectWebSocket];
    
    // Simulação para desenvolvimento
    [self captureAndSendTestImage];
}

- (void)stopWebRTC {
    if (self.frameTimer) {
        [self.frameTimer invalidate];
        self.frameTimer = nil;
    }
    
    [self.webSocketTask cancel];
    self.webSocketTask = nil;
    
    [self.peerConnection close];
    self.peerConnection = nil;
    
    self.videoTrack = nil;
}

- (void)connectWebSocket {
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
            writeLog(@"WebSocket erro: %@", error);
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            
            if ([json[@"type"] isEqualToString:@"offer"]) {
                [weakSelf handleOfferWithSDP:json[@"sdp"]];
            }
        }
        
        // Continuar recebendo mensagens
        [weakSelf receiveMessage];
    }];
}

- (void)handleOfferWithSDP:(NSString *)sdp {
    RTCSessionDescription *remoteSDP = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:remoteSDP completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"Erro setRemoteDescription: %@", error);
            return;
        }
        
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{} optionalConstraints:@{}];
        
        [weakSelf.peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription *answer, NSError *error) {
            if (error) {
                writeLog(@"Erro answerForConstraints: %@", error);
                return;
            }
            
            [weakSelf.peerConnection setLocalDescription:answer completionHandler:^(NSError *error) {
                if (error) {
                    writeLog(@"Erro setLocalDescription: %@", error);
                    return;
                }
                
                NSDictionary *response = @{
                    @"type": @"answer",
                    @"sdp": answer.sdp
                };
                
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                
                NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
                [weakSelf.webSocketTask sendMessage:message completionHandler:^(NSError *error) {
                    if (error) {
                        writeLog(@"Erro ao enviar resposta: %@", error);
                    }
                }];
            }];
        }];
    }];
}

#pragma mark - URLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    NSDictionary *joinMsg = @{@"type": @"join", @"roomId": @"ios-camera"};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:joinMsg options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
    [webSocketTask sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"Erro ao enviar mensagem de join: %@", error);
        }
    }];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.floatingWindow.statusLabel.text = @"Conectado";
    });
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
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updatePreviewImage:image];
    });
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.floatingWindow.statusLabel.text = @"Stream recebido";
            
            // Iniciar o timer para simulação
            if (!self.frameTimer) {
                self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                                  target:self
                                                                selector:@selector(captureAndSendTestImage)
                                                                userInfo:nil
                                                                 repeats:YES];
            }
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    // Implementação vazia
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    // Implementação vazia
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    // Implementação vazia
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    // Implementação vazia
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    // Implementação vazia
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
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
            writeLog(@"Erro ao enviar candidato ICE: %@", error);
        }
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    // Implementação vazia
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    // Implementação vazia
}

@end
