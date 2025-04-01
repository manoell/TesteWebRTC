#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>
#import "Logger.h"

// Variáveis globais para gerenciamento de recursos
static BOOL g_webrtcActive = NO;                           // Flag que indica se substituição por WebRTC está ativa
static NSString *g_serverIP = @"192.168.0.1";              // IP padrão do servidor WebRTC
static AVSampleBufferDisplayLayer *g_previewLayer = nil;   // Layer para visualização da câmera
static BOOL g_cameraRunning = NO;                          // Flag que indica se a câmera está ativa
static NSString *g_cameraPosition = @"B";                  // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // Orientação do vídeo/foto
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait; // Última orientação para otimização
static NSUserDefaults *g_settings = nil;                   // Para armazenamento de configurações
static NSTimeInterval g_volume_up_time = 0;                // Timestamp para detecção de botão de volume up
static NSTimeInterval g_volume_down_time = 0;              // Timestamp para detecção de botão de volume down

// Classe para gerenciamento de WebRTC
@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate, RTCVideoRenderer>

// Propriedades
@property (nonatomic, strong) NSString *serverIP;
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) RTCCVPixelBuffer *lastFrame;
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, assign) BOOL active;

// Métodos
+ (instancetype)sharedInstance;
- (void)startWebRTC;
- (void)stopWebRTC;
- (CMSampleBufferRef)getLatestVideoSampleBuffer;
- (BOOL)isConnected;

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
        _serverIP = g_serverIP;
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

// Função para obter a janela principal do aplicativo
static UIWindow* getKeyWindow() {
    vcam_log(@"Buscando janela principal");
    
    UIWindow *keyWindow = nil;
    NSArray *windows = UIApplication.sharedApplication.windows;
    for(UIWindow *window in windows){
        if(window.isKeyWindow) {
            keyWindow = window;
            vcam_log(@"Janela principal encontrada");
            break;
        }
    }
    return keyWindow;
}

// Funções de gestão de configurações
static void saveSettings() {
    if (g_settings) {
        [g_settings setObject:g_serverIP forKey:@"serverIP"];
        [g_settings setBool:g_webrtcActive forKey:@"webrtcActive"];
        [g_settings synchronize];
        vcam_logf(@"Configurações salvas: IP=%@, substituição=%@",
                g_serverIP, g_webrtcActive ? @"ativa" : @"inativa");
    }
}

static void loadSettings() {
    g_settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.vcam.webrtctweak"];
    
    if ([g_settings objectForKey:@"serverIP"]) {
        g_serverIP = [g_settings stringForKey:@"serverIP"];
    }
    
    g_webrtcActive = [g_settings boolForKey:@"webrtcActive"];
    
    vcam_logf(@"Configurações carregadas: IP=%@, substituição=%@",
            g_serverIP, g_webrtcActive ? @"ativa" : @"inativa");
    
    // Aplicar configurações carregadas
    if (g_webrtcActive) {
        WebRTCManager *manager = [WebRTCManager sharedInstance];
        manager.serverIP = g_serverIP;
        [manager startWebRTC];
    }
}

// Função para mostrar o menu de configuração
static void showConfigMenu() {
    vcam_log(@"Abrindo menu de configuração");
    
    WebRTCManager *webRTCManager = [WebRTCManager sharedInstance];
    
    // Determina o status atual para mostrar corretamente no menu
    NSString *statusText = g_webrtcActive ? @"Substituição ativa" : @"Substituição inativa";
    NSString *connectionStatus = @"Desconectado";
    
    if (webRTCManager.isConnected) {
        connectionStatus = webRTCManager.isReceivingFrames ? @"Recebendo stream" : @"Conectado, sem stream";
    }
    
    // Cria o alerta para o menu principal
    UIAlertController *alertController = [UIAlertController
        alertControllerWithTitle:@"WebRTC Camera"
        message:[NSString stringWithFormat:@"Status: %@\nServidor: %@\nConexão: %@",
                statusText, g_serverIP, connectionStatus]
        preferredStyle:UIAlertControllerStyleAlert];
    
    // Ação para configurar o IP do servidor
    UIAlertAction *configIPAction = [UIAlertAction
        actionWithTitle:@"Configurar IP do servidor"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            vcam_log(@"Opção 'Configurar IP' escolhida");
            
            UIAlertController *ipAlert = [UIAlertController
                alertControllerWithTitle:@"Configurar Servidor"
                message:@"Digite o IP do servidor WebRTC:"
                preferredStyle:UIAlertControllerStyleAlert];
            
            [ipAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                textField.text = g_serverIP;
                textField.keyboardType = UIKeyboardTypeURL;
                textField.autocorrectionType = UITextAutocorrectionTypeNo;
            }];
            
            UIAlertAction *saveAction = [UIAlertAction
                actionWithTitle:@"Salvar"
                style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    NSString *newIP = ipAlert.textFields.firstObject.text;
                    if (newIP && newIP.length > 0) {
                        g_serverIP = newIP;
                        webRTCManager.serverIP = newIP;
                        saveSettings();
                        
                        // Se a substituição estiver ativa, reiniciar a conexão
                        if (g_webrtcActive) {
                            [webRTCManager stopWebRTC];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [webRTCManager startWebRTC];
                            });
                        }
                        
                        // Mostrar confirmação
                        UIAlertController *confirmAlert = [UIAlertController
                            alertControllerWithTitle:@"Sucesso"
                            message:[NSString stringWithFormat:@"IP do servidor definido para: %@", g_serverIP]
                            preferredStyle:UIAlertControllerStyleAlert];
                        
                        UIAlertAction *okAction = [UIAlertAction
                            actionWithTitle:@"OK"
                            style:UIAlertActionStyleDefault
                            handler:nil];
                        
                        [confirmAlert addAction:okAction];
                        [getKeyWindow().rootViewController presentViewController:confirmAlert animated:YES completion:nil];
                    }
                }];
            
            UIAlertAction *cancelAction = [UIAlertAction
                actionWithTitle:@"Cancelar"
                style:UIAlertActionStyleCancel
                handler:nil];
            
            [ipAlert addAction:saveAction];
            [ipAlert addAction:cancelAction];
            
            [getKeyWindow().rootViewController presentViewController:ipAlert animated:YES completion:nil];
        }];
    
    // Ação para ativar/desativar a substituição
    NSString *toggleTitle = g_webrtcActive ? @"Desativar substituição" : @"Ativar substituição";
    UIAlertAction *toggleAction = [UIAlertAction
        actionWithTitle:toggleTitle
        style:g_webrtcActive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            vcam_log(@"Opção de alternar substituição escolhida");
            
            g_webrtcActive = !g_webrtcActive;
            saveSettings();
            
            if (g_webrtcActive) {
                [webRTCManager startWebRTC];
                
                // Avisa o usuário que a substituição foi ativada
                UIAlertController *successAlert = [UIAlertController
                    alertControllerWithTitle:@"Sucesso"
                    message:@"A substituição da câmera foi ativada."
                    preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction *okAction = [UIAlertAction
                    actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:nil];
                
                [successAlert addAction:okAction];
                [getKeyWindow().rootViewController presentViewController:successAlert animated:YES completion:nil];
            } else {
                [webRTCManager stopWebRTC];
                
                // Avisa o usuário que a substituição foi desativada
                UIAlertController *successAlert = [UIAlertController
                    alertControllerWithTitle:@"Sucesso"
                    message:@"A substituição da câmera foi desativada."
                    preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction *okAction = [UIAlertAction
                    actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:nil];
                
                [successAlert addAction:okAction];
                [getKeyWindow().rootViewController presentViewController:successAlert animated:YES completion:nil];
            }
        }];
    
    // Ação para ver status detalhado
    UIAlertAction *statusAction = [UIAlertAction
        actionWithTitle:@"Ver status detalhado"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            vcam_log(@"Opção 'Ver status detalhado' escolhida");
            
            // Coleta informações detalhadas de status
            NSMutableString *statusInfo = [NSMutableString string];
            [statusInfo appendFormat:@"Substituição: %@\n", g_webrtcActive ? @"Ativa" : @"Inativa"];
            [statusInfo appendFormat:@"Servidor: %@\n", g_serverIP];
            [statusInfo appendFormat:@"Câmera ativa: %@\n", g_cameraRunning ? @"Sim" : @"Não"];
            [statusInfo appendFormat:@"Posição da câmera: %@\n", g_cameraPosition];
            [statusInfo appendFormat:@"Orientação: %d\n", (int)g_photoOrientation];
            
            // Informações de conexão WebRTC
            if (webRTCManager) {
                [statusInfo appendFormat:@"Conexão WebRTC: %@\n", webRTCManager.isConnected ? @"Estabelecida" : @"Não estabelecida"];
                [statusInfo appendFormat:@"Recebendo frames: %@\n", webRTCManager.isReceivingFrames ? @"Sim" : @"Não"];
            }
            
            [statusInfo appendFormat:@"Aplicativo: %@", [NSProcessInfo processInfo].processName];
            
            // Cria alerta com as informações detalhadas
            UIAlertController *statusAlert = [UIAlertController
                alertControllerWithTitle:@"Status Detalhado"
                message:statusInfo
                preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction *okAction = [UIAlertAction
                actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault
                handler:nil];
            
            [statusAlert addAction:okAction];
            [getKeyWindow().rootViewController presentViewController:statusAlert animated:YES completion:nil];
        }];
    
    // Ação para fechar o menu
    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:@"Fechar"
        style:UIAlertActionStyleCancel
        handler:nil];
    
    // Adiciona as ações ao alerta
    [alertController addAction:configIPAction];
    [alertController addAction:toggleAction];
    [alertController addAction:statusAction];
    [alertController addAction:cancelAction];
    
    // Apresenta o alerta
    [getKeyWindow().rootViewController presentViewController:alertController animated:YES completion:nil];
}

// Camada para cobrir visualização original da câmera
static CALayer *g_maskLayer = nil;

// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer{
    vcam_log(@"AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer");
    %orig;

    // Configura display link para atualização contínua
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        
        // Ajusta a taxa de frames baseado no dispositivo
        if (@available(iOS 10.0, *)) {
            displayLink.preferredFramesPerSecond = 30; // 30 FPS para economia de bateria
        } else {
            displayLink.frameInterval = 2; // Aproximadamente 30 FPS em dispositivos mais antigos
        }
        
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        vcam_log(@"DisplayLink criado para atualização contínua");
    }

    // Adiciona camada de preview se ainda não existe
    if (![[self sublayers] containsObject:g_previewLayer]) {
        vcam_log(@"Configurando camadas de preview");
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // Máscara preta para cobrir a visualização original
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        g_maskLayer.opacity = 0; // Começa invisível
        
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        g_previewLayer.opacity = 0; // Começa invisível

        // Inicializa tamanho das camadas na thread principal
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            g_maskLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            vcam_log(@"Tamanho das camadas inicializado");
        });
    }
}

// Método adicionado para atualização contínua do preview
%new
-(void)step:(CADisplayLink *)sender {
    // Verificar se a substituição está ativa
    if (!g_webrtcActive) {
        // Esconder as camadas se estiverem visíveis
        if (g_maskLayer != nil && g_maskLayer.opacity > 0.0) {
            g_maskLayer.opacity = MAX(g_maskLayer.opacity - 0.1, 0.0);
        }
        if (g_previewLayer != nil && g_previewLayer.opacity > 0.0) {
            g_previewLayer.opacity = MAX(g_previewLayer.opacity - 0.1, 0.0);
        }
        return;
    }
    
    // Verificar se está recebendo frames WebRTC
    WebRTCManager *manager = [WebRTCManager sharedInstance];
    BOOL receivingFrames = manager.isReceivingFrames;
    
    // Controla a visibilidade das camadas baseado na recepção de frames
    if (receivingFrames) {
        // Animação suave para mostrar as camadas, se não estiverem visíveis
        if (g_maskLayer != nil && g_maskLayer.opacity < 1.0) {
            g_maskLayer.opacity = MIN(g_maskLayer.opacity + 0.1, 1.0);
        }
        if (g_previewLayer != nil) {
            if (g_previewLayer.opacity < 1.0) {
                g_previewLayer.opacity = MIN(g_previewLayer.opacity + 0.1, 1.0);
            }
            [g_previewLayer setVideoGravity:[self videoGravity]];
        }
    } else {
        // Se não está recebendo frames, esconder as camadas
        if (g_maskLayer != nil && g_maskLayer.opacity > 0.0) {
            g_maskLayer.opacity = MAX(g_maskLayer.opacity - 0.1, 0.0);
        }
        if (g_previewLayer != nil && g_previewLayer.opacity > 0.0) {
            g_previewLayer.opacity = MAX(g_previewLayer.opacity - 0.1, 0.0);
        }
        return;
    }

    // Se a câmera está ativa e a camada de preview existe
    if (g_cameraRunning && g_previewLayer != nil) {
        // Atualiza o tamanho da camada de preview
        if (!CGRectEqualToRect(g_previewLayer.frame, self.bounds)) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
        }
        
        // Aplica rotação apenas se a orientação mudou
        if (g_photoOrientation != g_lastOrientation) {
            g_lastOrientation = g_photoOrientation;
            
            // Atualiza a orientação do vídeo
            switch(g_photoOrientation) {
                case AVCaptureVideoOrientationPortrait:
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    g_previewLayer.transform = CATransform3DMakeRotation(0 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                case AVCaptureVideoOrientationLandscapeRight:
                    g_previewLayer.transform = CATransform3DMakeRotation(90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    g_previewLayer.transform = CATransform3DMakeRotation(-90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                default:
                    g_previewLayer.transform = self.transform;
            }
        }

        // Atualiza o preview a cada 30 FPS
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval currentTime = CACurrentMediaTime() * 1000;
        
        if (currentTime - refreshTime > 1000 / 30) {
            refreshTime = currentTime;
            
            // Atualiza a camada de preview com o frame WebRTC
            CMSampleBufferRef sampleBuffer = [manager getLatestVideoSampleBuffer];
            if (sampleBuffer && g_previewLayer.readyForMoreMediaData) {
                [g_previewLayer flush];
                [g_previewLayer enqueueSampleBuffer:sampleBuffer];
                CFRelease(sampleBuffer);
            }
        }
    }
}
%end

// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
// Método chamado quando a câmera é iniciada
-(void) startRunning {
    vcam_log(@"AVCaptureSession::startRunning - Câmera iniciando");
    g_cameraRunning = YES;
    
    %orig;
    
    // Se a substituição estiver ativa, iniciar WebRTC
    if (g_webrtcActive) {
        WebRTCManager *manager = [WebRTCManager sharedInstance];
        [manager startWebRTC];
    }
    
    vcam_log(@"Câmera iniciada");
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    vcam_log(@"AVCaptureSession::stopRunning - Câmera parando");
    g_cameraRunning = NO;
    
    %orig;
    
    vcam_log(@"Câmera parada");
}

// Método chamado quando um dispositivo de entrada é adicionado à sessão
- (void)addInput:(AVCaptureDeviceInput *)input {
    vcam_log(@"AVCaptureSession::addInput - Adicionando dispositivo");
    
    // Determina qual câmera está sendo usada (frontal ou traseira)
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
        vcam_logf(@"Posição da câmera definida como: %@", g_cameraPosition);
    }
    
    %orig;
}
%end

// Hook para intercepção do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    vcam_log(@"AVCaptureVideoDataOutput::setSampleBufferDelegate - Configurando delegate");
    
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        vcam_log(@"Delegate ou queue nulos, chamando método original sem modificações");
        return %orig;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static NSMutableArray *hooked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooked = [NSMutableArray new];
    });
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    
    // Verifica se esta classe já foi "hooked"
    if (![hooked containsObject:className]) {
        vcam_logf(@"Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;

        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Armazena a orientação atual do vídeo
                g_photoOrientation = [connection videoOrientation];
                
                // Verifica se a substituição está ativa e se temos um gerenciador WebRTC
                WebRTCManager *manager = [WebRTCManager sharedInstance];
                if (g_webrtcActive && manager.isReceivingFrames) {
                    // Obtém um frame do WebRTC para substituir o buffer
                    CMSampleBufferRef webrtcBuffer = [manager getLatestVideoSampleBuffer];
                    
                    // Se temos um buffer WebRTC válido
                    if (webrtcBuffer != nil) {
                        // Chamada do método original com o buffer substituído
                        original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                     output, webrtcBuffer, connection);
                        
                        // Libera o buffer após uso
                        CFRelease(webrtcBuffer);
                        return;
                    }
                }
                
                // Se não há substituição ativa, usa o buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}
%end

// Hook para os controles de volume (acesso ao menu)
%hook VolumeControl
// Método chamado quando volume é aumentado
-(void)increaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Salva o timestamp atual
    g_volume_up_time = nowtime;
    
    // Chama o método original
    %orig;
}

// Método chamado quando volume é diminuído
-(void)decreaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Verifica se o botão de aumentar volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 1) {
        vcam_log(@"Sequência volume-up + volume-down detectada, abrindo menu");
        showConfigMenu();
    }
    
    // Salva o timestamp atual
    g_volume_down_time = nowtime;
    
    // Chama o método original
    %orig;
}
%end

// Função chamada quando o tweak é carregado
%ctor {
    vcam_log(@"--------------------------------------------------");
    vcam_log(@"[WebRTCTweak] Inicializando tweak");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        vcam_log(@"Detectado iOS 13 ou superior, inicializando hooks para VolumeControl");
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Carregar configurações
    loadSettings();
    
    vcam_logf(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    vcam_logf(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    vcam_log(@"Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor {
    vcam_log(@"[WebRTCTweak] Finalizando tweak");
    
    // Desativa WebRTC
    if (g_webrtcActive) {
        [[WebRTCManager sharedInstance] stopWebRTC];
    }
    
    // Remover camadas de preview
    if (g_previewLayer) {
        [g_previewLayer removeFromSuperlayer];
        g_previewLayer = nil;
    }
    
    // Remover camada de máscara
    if (g_maskLayer) {
        [g_maskLayer removeFromSuperlayer];
        g_maskLayer = nil;
    }
    
    // Resetar estados
    g_cameraRunning = NO;
    g_webrtcActive = NO;
    
    // Salvar configurações finais
    saveSettings();
    
    vcam_log(@"Tweak finalizado com sucesso");
    vcam_log(@"--------------------------------------------------");
}
