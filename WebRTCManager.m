#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "WebRTCFrameConverter.h"
#import "logger.h"

// Definição para notificação customizada de mudança de câmera
static NSString *const AVCaptureDevicePositionDidChangeNotification = @"AVCaptureDevicePositionDidChangeNotification";

// Definições para alta qualidade de vídeo
#define kPreferredMaxWidth 1920
#define kPreferredMaxHeight 1080
#define kPreferredMaxFPS 30

@interface WebRTCManager ()
@property (nonatomic, assign) BOOL isReceivingFrames;
@property (nonatomic, assign) int reconnectAttempts;
@property (nonatomic, strong) NSTimer *reconnectTimer;
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic, assign) CFTimeInterval connectionStartTime;
@property (nonatomic, assign) BOOL hasReceivedFirstFrame;
@property (nonatomic, strong) NSMutableDictionary *sdpMediaConstraints;
@end

@implementation WebRTCManager

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        self.floatingWindow = window;
        self.isConnected = NO;
        self.isReceivingFrames = NO;
        self.reconnectAttempts = 0;
        self.hasReceivedFirstFrame = NO;
        self.frameConverter = [[WebRTCFrameConverter alloc] init];
        
        // Inicializar constraints para mídia de alta qualidade
        self.sdpMediaConstraints = [NSMutableDictionary dictionaryWithDictionary:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        }];
        
        // Configurar o callback do frame converter para atualizar a UI
        __weak typeof(self) weakSelf = self;
        self.frameConverter.frameCallback = ^(UIImage *image) {
            if (!weakSelf.hasReceivedFirstFrame) {
                weakSelf.hasReceivedFirstFrame = YES;
                CFTimeInterval timeToFirstFrame = CACurrentMediaTime() - weakSelf.connectionStartTime;
                writeLog(@"[WebRTCManager] Primeiro frame recebido após %.2f segundos", timeToFirstFrame);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.floatingWindow updateConnectionStatus:
                     [NSString stringWithFormat:@"Stream ativo (%.1fs)", timeToFirstFrame]];
                });
            }
            
            [weakSelf.floatingWindow updatePreviewImage:image];
            weakSelf.isReceivingFrames = YES;
        };
        
        writeLog(@"[WebRTCManager] WebRTCManager inicializado com configurações para alta qualidade");
    }
    return self;
}

- (void)startWebRTC {
    writeLog(@"[WebRTCManager] Iniciando WebRTC");
    
    self.connectionStartTime = CACurrentMediaTime();
    self.hasReceivedFirstFrame = NO;
    
    [self configureWebRTC];
    [self connectWebSocket];
    
    // Para depuração - mostrar uma imagem de teste enquanto aguarda conexão
    [self captureAndSendTestImage];
    
    // Evitar memory leak
    __weak typeof(self) weakSelf = self;
    
    // Iniciar um timer para mostrar imagens de teste durante a conexão
    self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(captureAndSendTestImage)
                                                   userInfo:nil
                                                    repeats:YES];
    
    // Verificar status após 5 segundos
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf checkWebRTCStatus];
        
        // Configurar timer de estatísticas
        weakSelf.statsTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                            target:weakSelf
                                                          selector:@selector(gatherConnectionStats)
                                                          userInfo:nil
                                                           repeats:YES];
        
        // Configurar verificações periódicas
        weakSelf.reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                               target:weakSelf
                                                             selector:@selector(periodicStatusCheck)
                                                             userInfo:nil
                                                              repeats:YES];
    });
}

- (void)gatherConnectionStats {
    if (!self.peerConnection) {
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        writeLog(@"[WebRTCManager] Estatísticas de conexão coletadas");
        
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
                        NSString *mimeType = [mimeTypeObj isKindOfClass:[NSString class]] ? (NSString *)mimeTypeObj : @"unknown";
                        // Verificação de tipo para evitar erro de incompatibilidade
                        if ([mimeType isKindOfClass:[NSString class]]) {
                            codecName = mimeType;
                        }
                        statsData[@"codec"] = codecName;
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
        
        // Log de estatísticas relevantes
        writeLog(@"[WebRTCManager] Qualidade de vídeo: %dx%d @ %.1f fps, codec: %@",
                frameWidth, frameHeight, frameRate, codecName);
        writeLog(@"[WebRTCManager] Estatísticas de rede: %d pacotes recebidos, %.1f%% perdidos",
                totalPacketsReceived, lossRate);
        
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

- (void)periodicStatusCheck {
    [self checkWebRTCStatus];
    
    // Verificar se a conexão está saudável
    if (!self.isConnected && self.reconnectAttempts < 3) {
        writeLog(@"[WebRTCManager] Não está conectado, tentativa de reconexão %d/3", self.reconnectAttempts + 1);
        self.reconnectAttempts++;
        
        // Desconectar completamente antes de tentar novamente
        [self stopWebRTC];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self startWebRTC];
        });
    }
    else if (self.isConnected && !self.isReceivingFrames && self.hasReceivedFirstFrame) {
        // Se estivermos conectados mas não recebendo frames (após já ter recebido o primeiro)
        writeLog(@"[WebRTCManager] Conectado mas sem receber frames - possível problema");
        
        // Tentar reconectar o renderer
        if (self.videoTrack) {
            writeLog(@"[WebRTCManager] Tentando reconectar o renderer ao video track");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.floatingWindow updateConnectionStatus:@"Reconectando renderer..."];
            });
            
            [self.videoTrack removeRenderer:self.frameConverter];
            [self.videoTrack addRenderer:self.frameConverter];
        }
    }
    else if (self.isConnected && self.isReceivingFrames) {
        // Reset contador de reconexão quando tudo está funcionando
        self.reconnectAttempts = 0;
    }
}

- (void)configureWebRTC {
    writeLog(@"[WebRTCManager] Configurando WebRTC para alta qualidade");
    
    // Configuração aprimorada de WebRTC para alta qualidade
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    
    // Usar múltiplos servidores STUN para melhor conectividade
    config.iceServers = @[
        [[RTCIceServer alloc] initWithURLStrings:@[
            @"stun:stun.l.google.com:19302",
            @"stun:stun1.l.google.com:19302",
            @"stun:stun2.l.google.com:19302",
            @"stun:stun3.l.google.com:19302"
        ]]
    ];
    
    // Configurações avançadas para melhor desempenho
    config.iceTransportPolicy = RTCIceTransportPolicyAll;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled;
    config.candidateNetworkPolicy = RTCCandidateNetworkPolicyAll;
    
    // Semântica SDP unificada para melhor compatibilidade
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    
    // Configurar tempos de ICE para aceleração de conexão
    config.iceConnectionReceivingTimeout = 15000; // 15 segundos
    config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
    
    // Configurações específicas para receber vídeo de alta qualidade
    NSDictionary *mandatoryConstraints = [self.sdpMediaConstraints copy];
    
    NSDictionary *optionalConstraints = @{
        @"DtlsSrtpKeyAgreement": @"true",
        @"RtpDataChannels": @"false"
    };
    
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                      initWithMandatoryConstraints:mandatoryConstraints
                                      optionalConstraints:optionalConstraints];
    
    // Verificar se o factory pode ser criado com encoder/decoder
    if ([RTCPeerConnectionFactory instancesRespondToSelector:@selector(initWithEncoderFactory:decoderFactory:)]) {
        // Criar factory com suporte para codecs específicos
        RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        
        // Registrar codecs adicionais ou configurar os existentes pode ser feito aqui
        
        self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                 decoderFactory:decoderFactory];
        
        writeLog(@"[WebRTCManager] Factory inicializada com encoder/decoder personalizados para alta qualidade");
    } else {
        self.factory = [[RTCPeerConnectionFactory alloc] init];
        writeLog(@"[WebRTCManager] Factory inicializada com método padrão");
    }
    
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                           constraints:constraints
                                                              delegate:self];
    
    writeLog(@"[WebRTCManager] WebRTC configurado para recepção de vídeo em alta qualidade");
}

- (void)stopWebRTC {
    writeLog(@"[WebRTCManager] Parando WebRTC");
    
    self.isConnected = NO;
    self.isReceivingFrames = NO;
    
    if (self.frameTimer) {
        [self.frameTimer invalidate];
        self.frameTimer = nil;
    }
    
    if (self.reconnectTimer) {
        [self.reconnectTimer invalidate];
        self.reconnectTimer = nil;
    }
    
    if (self.statsTimer) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
    
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self.frameConverter];
        self.videoTrack = nil;
    }
    
    [self.webSocketTask cancel];
    self.webSocketTask = nil;
    
    if (self.peerConnection) {
        [self.peerConnection close];
        self.peerConnection = nil;
    }
    
    // Liberar fábrica
    self.factory = nil;
}

- (void)connectWebSocket {
    writeLog(@"[WebRTCManager] Conectando ao WebSocket");
    
    // Atualizar para seu IP real - importante que seja acessível do dispositivo iOS
    NSURL *url = [NSURL URLWithString:@"ws://192.168.0.178:8080"];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;  // Aumentar timeout para 30 segundos
    config.timeoutIntervalForResource = 60.0; // Timeout total de 60 segundos
    
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    self.webSocketTask = [self.session webSocketTaskWithRequest:request];
    [self.webSocketTask resume];
    
    [self receiveMessage];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:@"Conectando ao servidor..."];
    });
}

- (void)receiveMessage {
    if (!self.webSocketTask) return;
    
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] WebSocket erro: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Erro WebSocket: %@", error.localizedDescription]];
            });
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            
            if (jsonError) {
                writeLog(@"[WebRTCManager] Erro ao analisar JSON: %@", jsonError);
                writeLog(@"[WebRTCManager] Conteúdo da mensagem: %@", message.string);
                // Continuar recebendo mensagens
                [weakSelf receiveMessage];
                return;
            }
            
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
                
                // Verificar codecs
                NSArray *codecs = @[@"H264", @"VP8", @"VP9", @"AV1"];
                for (NSString *codec in codecs) {
                    if ([sdp containsString:codec]) {
                        writeLog(@"[WebRTCManager] Codec %@ encontrado na oferta", codec);
                    }
                }
                
                // Verificar perfil H264 (para alta qualidade)
                if ([sdp containsString:@"profile-level-id"]) {
                    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"profile-level-id=([0-9a-fA-F]+)" options:0 error:nil];
                    NSArray *matches = [regex matchesInString:sdp options:0 range:NSMakeRange(0, sdp.length)];
                    
                    for (NSTextCheckingResult *match in matches) {
                        if ([match numberOfRanges] >= 2) {
                            NSRange profileRange = [match rangeAtIndex:1];
                            NSString *profileId = [sdp substringWithRange:profileRange];
                            writeLog(@"[WebRTCManager] Perfil H264 encontrado: %@", profileId);
                        }
                    }
                }
                
                [weakSelf handleOfferWithSDP:sdp];
            }
            else if ([type isEqualToString:@"ice-candidate"]) {
                NSString *sdp = json[@"candidate"];
                NSString *sdpMid = json[@"sdpMid"];
                NSNumber *sdpMLineIndex = json[@"sdpMLineIndex"];
                
                if (!sdp || !sdpMid || !sdpMLineIndex) {
                    writeLog(@"[WebRTCManager] Candidato ICE inválido recebido");
                    [weakSelf receiveMessage];
                    return;
                }
                
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
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:@"Processando oferta..."];
    });
    
    // Verificar se a SDP contém mídia de vídeo
    NSArray *lines = [sdp componentsSeparatedByString:@"\n"];
    BOOL hasVideoMedia = NO;
    BOOL hasVideoCodec = NO;
    BOOL hasH264 = NO;
    BOOL hasVP8 = NO;
    BOOL hasVP9 = NO;
    
    // Análise mais detalhada da SDP
    for (NSString *line in lines) {
        if ([line hasPrefix:@"m=video"]) {
            hasVideoMedia = YES;
            writeLog(@"[WebRTCManager] Linha de mídia de vídeo encontrada: %@", line);
        }
        
        // Verificar codecs de vídeo
        if (hasVideoMedia) {
            if ([line hasPrefix:@"a=rtpmap:"] && [line containsString:@"H264"]) {
                hasVideoCodec = YES;
                hasH264 = YES;
                writeLog(@"[WebRTCManager] Codec H264 encontrado: %@", line);
            }
            else if ([line hasPrefix:@"a=rtpmap:"] && [line containsString:@"VP8"]) {
                hasVideoCodec = YES;
                hasVP8 = YES;
                writeLog(@"[WebRTCManager] Codec VP8 encontrado: %@", line);
            }
            else if ([line hasPrefix:@"a=rtpmap:"] && [line containsString:@"VP9"]) {
                hasVideoCodec = YES;
                hasVP9 = YES;
                writeLog(@"[WebRTCManager] Codec VP9 encontrado: %@", line);
            }
            
            // Verificar perfil H264 (indicativo de suporte a alta resolução)
            if ([line hasPrefix:@"a=fmtp:"] && [line containsString:@"profile-level-id="]) {
                writeLog(@"[WebRTCManager] Parâmetros de formato H264: %@", line);
            }
        }
    }
    
    if (!hasVideoMedia) {
        writeLog(@"[WebRTCManager] AVISO: A oferta SDP não contém mídia de vídeo!");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Erro: Sem vídeo na oferta"];
        });
    }
    
    if (!hasVideoCodec) {
        writeLog(@"[WebRTCManager] AVISO: Nenhum codec de vídeo conhecido encontrado na oferta!");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Erro: Codec de vídeo não suportado"];
        });
    } else {
        // Log dos codecs encontrados
        writeLog(@"[WebRTCManager] Suporte a codecs: H264=%@, VP8=%@, VP9=%@",
                hasH264 ? @"Sim" : @"Não",
                hasVP8 ? @"Sim" : @"Não",
                hasVP9 ? @"Sim" : @"Não");
    }
    
    // Modificar SDP para forçar alta qualidade, se necessário
    NSString *modifiedSdp = [self enhanceSdpForHighQuality:sdp];
    
    // Continuar com o processamento da oferta modificada
    RTCSessionDescription *remoteSDP = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:modifiedSdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:remoteSDP completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro setRemoteDescription: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.floatingWindow updateConnectionStatus:@"Erro na descrição remota"];
            });
            return;
        }
        
        writeLog(@"[WebRTCManager] RemoteDescription definido com sucesso");
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.floatingWindow updateConnectionStatus:@"Descrição remota OK"];
        });
        
        // Configurações específicas para a resposta
        NSDictionary *mandatoryConstraints = [weakSelf.sdpMediaConstraints copy];
        
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                          initWithMandatoryConstraints:mandatoryConstraints
                                          optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription *answer, NSError *error) {
            if (error) {
                writeLog(@"[WebRTCManager] Erro answerForConstraints: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.floatingWindow updateConnectionStatus:@"Erro ao criar resposta"];
                });
                return;
            }
            
            writeLog(@"[WebRTCManager] Resposta SDP criada com sucesso");
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.floatingWindow updateConnectionStatus:@"Enviando resposta..."];
            });
            
            // Analisar a resposta SDP gerada
            NSString *answerSdp = answer.sdp;
            BOOL responseHasVideo = [answerSdp containsString:@"m=video"];
            writeLog(@"[WebRTCManager] A resposta SDP contém vídeo: %@",
                    responseHasVideo ? @"Sim" : @"Não");
            
            // Verificar codecs na resposta
            if ([answerSdp containsString:@"H264"]) {
                writeLog(@"[WebRTCManager] Resposta usando codec H264");
            } else if ([answerSdp containsString:@"VP8"]) {
                writeLog(@"[WebRTCManager] Resposta usando codec VP8");
            } else if ([answerSdp containsString:@"VP9"]) {
                writeLog(@"[WebRTCManager] Resposta usando codec VP9");
            }
            
            // Modificar a resposta SDP para otimização
            NSString *optimizedAnswerSdp = [weakSelf enhanceSdpForHighQuality:answerSdp];
            RTCSessionDescription *optimizedAnswer = [[RTCSessionDescription alloc]
                                                    initWithType:RTCSdpTypeAnswer
                                                           sdp:optimizedAnswerSdp];
            
            [weakSelf.peerConnection setLocalDescription:optimizedAnswer completionHandler:^(NSError *error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro setLocalDescription: %@", error);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf.floatingWindow updateConnectionStatus:@"Erro na descrição local"];
                    });
                    return;
                }
                
                writeLog(@"[WebRTCManager] LocalDescription definido com sucesso");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.floatingWindow updateConnectionStatus:@"Descrição local OK"];
                });
                
                NSDictionary *response = @{
                    @"type": @"answer",
                    @"sdp": weakSelf.peerConnection.localDescription.sdp
                };
                
                NSError *jsonError;
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:response options:0 error:&jsonError];
                
                if (jsonError) {
                    writeLog(@"[WebRTCManager] Erro ao serializar JSON de resposta: %@", jsonError);
                    return;
                }
                
                NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                
                NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
                [weakSelf.webSocketTask sendMessage:message completionHandler:^(NSError *error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Erro ao enviar resposta: %@", error);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf.floatingWindow updateConnectionStatus:@"Erro ao enviar resposta"];
                        });
                    } else {
                        writeLog(@"[WebRTCManager] Resposta enviada com sucesso");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf.floatingWindow updateConnectionStatus:@"Resposta enviada"];
                        });
                    }
                }];
            }];
        }];
    }];
}

- (NSString *)enhanceSdpForHighQuality:(NSString *)originalSdp {
    // Esta função modifica a SDP para otimizar para alta qualidade de vídeo
    NSMutableArray *lines = [NSMutableArray arrayWithArray:[originalSdp componentsSeparatedByString:@"\n"]];
    NSMutableArray *result = [NSMutableArray array];
    
    BOOL inVideoSection = NO;
    BOOL videoSectionModified = NO;
    
    for (NSString *line in lines) {
        NSString *modifiedLine = line;
        
        // Detectar seção de vídeo
        if ([line hasPrefix:@"m=video"]) {
            inVideoSection = YES;
        } else if ([line hasPrefix:@"m="]) {
            inVideoSection = NO;
        }
        
        // Modificações para seção de vídeo
        if (inVideoSection) {
            // Modificar profile-level-id de H264 para suportar alta resolução
            if ([line containsString:@"profile-level-id"] && [line containsString:@"H264"]) {
                // Substituir por perfil de alta qualidade - 42e01f suporta até 1080p
                modifiedLine = [line stringByReplacingOccurrencesOfString:@"profile-level-id=[0-9a-fA-F]+"
                                                              withString:@"profile-level-id=42e01f"
                                                                 options:NSRegularExpressionSearch
                                                                   range:NSMakeRange(0, line.length)];
                videoSectionModified = YES;
            }
            
            // Adicionar configuração de bitrate se não existir
            if ([line hasPrefix:@"c="] && !videoSectionModified) {
                [result addObject:modifiedLine];
                // Adicionar linha de bitrate após a linha de conexão
                [result addObject:@"b=AS:5000"]; // 5 Mbps para permitir stream de alta qualidade
                videoSectionModified = YES;
                continue;
            }
        }
        
        [result addObject:modifiedLine];
    }
    
    return [result componentsJoinedByString:@"\n"];
}

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    return [self.frameConverter getLatestSampleBuffer];
}

- (void)captureAndSendTestImage {
    // Somente mostrar o indicador de teste se não estiver recebendo frames reais
    if (self.isConnected && self.isReceivingFrames) return;
    
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
    
    // Status da conexão
    NSString *statusText;
    if (self.isConnected) {
        if (self.isReceivingFrames) {
            statusText = @"Conectado - Recebendo quadros";
        } else {
            statusText = @"Conectado - Aguardando vídeo";
        }
    } else {
        statusText = @"Desconectado - Aguardando conexão";
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
            if (!self.isConnected) {
                [self.floatingWindow updateConnectionStatus:@"Sem conexão WebRTC"];
            } else if (!self.videoTrack) {
                [self.floatingWindow updateConnectionStatus:@"Sem trilha de vídeo"];
            }
        });
    }
    
    // Se estiver conectado mas sem receber frames por um tempo, tentar reiniciar o processo
    if (self.isConnected && !self.isReceivingFrames && self.videoTrack) {
        static int framesCheckCount = 0;
        framesCheckCount++;
        
        if (framesCheckCount >= 3) { // Após três verificações sem frames
            writeLog(@"[WebRTCManager] Detectado problema: conectado mas sem receber frames.");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.floatingWindow updateConnectionStatus:@"Reconectando track de vídeo..."];
            });
            
            // Tentar reconectar o renderer
            if (self.videoTrack) {
                [self.videoTrack removeRenderer:self.frameConverter];
                [self.videoTrack addRenderer:self.frameConverter];
                writeLog(@"[WebRTCManager] Renderer reconectado ao video track");
            }
            
            framesCheckCount = 0;
        }
    } else {
        // Reset contador se estiver recebendo frames ou não estiver conectado
        //static int framesCheckCount = 0;
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
    
    @try {
        // Logs detalhados dos video tracks
        for (RTCVideoTrack *track in stream.videoTracks) {
            writeLog(@"[WebRTCManager] Video track encontrado: ID=%@, habilitado=%@",
                    track.trackId,
                    track.isEnabled ? @"Sim" : @"Não");
        }
        
        if (stream.videoTracks.count > 0) {
            self.videoTrack = stream.videoTracks[0];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    [self.floatingWindow updateConnectionStatus:@"Stream recebido"];
                    
                    // Parar o timer de simulação quando receber um stream real
                    if (self.frameTimer) {
                        [self.frameTimer invalidate];
                        self.frameTimer = nil;
                    }
                    
                    // Conectar o video track ao renderer com tratamento de erros
                    if (self.videoTrack && self.frameConverter) {
                        // Remover primeiro para garantir que não há conexão duplicada
                        [self.videoTrack removeRenderer:self.frameConverter];
                        
                        // Adicionar o renderer
                        [self.videoTrack addRenderer:self.frameConverter];
                        self.isConnected = YES;
                        writeLog(@"[WebRTCManager] Renderer conectado ao video track");
                        
                        // Verificar recebimento de frames após um delay
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (!self.isReceivingFrames) {
                                writeLog(@"[WebRTCManager] Aviso: Video track conectado mas não está recebendo frames.");
                                [self.floatingWindow updateConnectionStatus:@"Sem recebimento de frames"];
                            }
                        });
                    } else {
                        writeLog(@"[WebRTCManager] ERRO: Não foi possível conectar o renderer");
                        [self.floatingWindow updateConnectionStatus:@"Erro ao conectar renderer"];
                    }
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCManager] Exceção ao processar stream: %@", exception);
                    [self.floatingWindow updateConnectionStatus:@"Erro no processamento do stream"];
                }
            });
        } else {
            writeLog(@"[WebRTCManager] Stream sem video tracks!");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.floatingWindow updateConnectionStatus:@"Stream sem video tracks"];
            });
        }
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao processar stream adicionado: %@", exception);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Erro ao processar stream"];
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
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Sinalização: %@", state]];
    });
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Negociação necessária");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *state = [self iceConnectionStateToString:newState];
    writeLog(@"[WebRTCManager] Estado da conexão ICE mudou para: %@", state);
    
    if (newState == RTCIceConnectionStateConnected || newState == RTCIceConnectionStateCompleted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"ICE: %@", state]];
        });
        
        // Agora é um bom momento para coletar estatísticas
        [self gatherConnectionStats];
    } else if (newState == RTCIceConnectionStateFailed || newState == RTCIceConnectionStateDisconnected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"ICE: %@ - Problema", state]];
            if (newState == RTCIceConnectionStateFailed) {
                self.isConnected = NO;
            }
        });
        
        // Tentar reiniciar ICE se falhar
        if (newState == RTCIceConnectionStateFailed) {
            writeLog(@"[WebRTCManager] Tentando reiniciar ICE após falha");
            [self.peerConnection restartIce];
        }
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
    
    // Atualizar UI somente durante a fase inicial de conexão
    if (!self.isConnected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"ICE Gathering: %@", state]];
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Candidato ICE gerado: %@", candidate.sdp);
    
    NSDictionary *iceCandidateDict = @{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex)
    };
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:iceCandidateDict options:0 error:&jsonError];
    
    if (jsonError) {
        writeLog(@"[WebRTCManager] Erro ao serializar candidato ICE: %@", jsonError);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
    [self.webSocketTask sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao enviar candidato ICE: %@", error);
        } else {
            writeLog(@"[WebRTCManager] Candidato ICE enviado com sucesso");
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
    
    // Reset contador de reconexão quando conectar com sucesso
    self.reconnectAttempts = 0;
    
    NSDictionary *joinMsg = @{@"type": @"join", @"roomId": @"ios-camera"};
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:joinMsg options:0 error:&jsonError];
    
    if (jsonError) {
        writeLog(@"[WebRTCManager] Erro ao serializar mensagem de join: %@", jsonError);
        return;
    }
    
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
            [self.floatingWindow updateConnectionStatus:@"Desconectado - Erro WebSocket"];
        });
        
        // Tentar reconectar automaticamente após erro de WebSocket
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf && !weakSelf.isConnected && weakSelf.reconnectAttempts < 3) {
                writeLog(@"[WebRTCManager] Tentando reconectar WebSocket após erro");
                [weakSelf connectWebSocket];
            }
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

#pragma mark - Auto-adaptação à câmera nativa

- (void)setAutoAdaptToCameraEnabled:(BOOL)enable {
    self.autoAdaptToCameraResolution = enable;
    
    writeLog(@"[WebRTCManager] Auto-adaptação à câmera nativa %@",
             enable ? @"ativada" : @"desativada");
    
    if (enable) {
        // Detectar a câmera ativa (assumindo traseira como padrão)
        [self adaptToNativeCameraWithPosition:AVCaptureDevicePositionBack];
    }
}

- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position {
    writeLog(@"[WebRTCManager] Detectando câmera %@ para adaptação",
             position == AVCaptureDevicePositionFront ? @"frontal" : @"traseira");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Buscar dispositivo de câmera usando AVCaptureDeviceDiscoverySession (método moderno)
        AVCaptureDevice *camera = nil;
        
        // Usar API moderna para iOS 10+
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
        });
    } else {
        writeLog(@"[WebRTCManager] Erro ao bloquear câmera para configuração: %@", error);
    }
}

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    [self.frameConverter setTargetResolution:resolution];
}

- (void)setTargetFrameRate:(float)frameRate {
    [self.frameConverter setTargetFrameRate:frameRate];
}

#pragma mark - Manipuladores de notificação para troca de câmera

- (void)setupCameraSwitchNotifications {
    // Registrar para notificações de troca de câmera
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleCameraChange:)
                                                 name:AVCaptureDeviceWasConnectedNotification
                                               object:nil];
    
    // Usar nossa notificação customizada definida no topo do arquivo
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleCameraChange:)
                                                 name:AVCaptureDevicePositionDidChangeNotification
                                               object:nil];
}

- (void)handleCameraChange:(NSNotification *)notification {
    if (!self.autoAdaptToCameraResolution) return;
    
    // Tentar determinar qual câmera está ativa
    AVCaptureDevice *device = notification.object;
    if ([device isKindOfClass:[AVCaptureDevice class]]) {
        [self extractCameraCapabilitiesAndAdapt:device];
    } else {
        // Se não conseguirmos determinar a câmera diretamente, tentar detectar
        // Primeiro tentar câmera frontal, já que é mais comum a troca para ela
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self adaptToNativeCameraWithPosition:AVCaptureDevicePositionFront];
        });
    }
}

@end
