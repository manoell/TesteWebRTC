#import "WebRTCManager.h"
#import "WebRTCBufferInjector.h"
#import "WebRTCCameraAdapter.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"

// Configurações globais
static NSString *g_serverIP = @"192.168.0.178"; // IP padrão do servidor
static BOOL g_replacementActive = NO; // Flag para controlar se a substituição está ativa
static NSUserDefaults *g_settings = nil; // Para armazenar configurações

// Componentes WebRTC
static WebRTCManager *g_webRTCManager = nil;
static WebRTCBufferInjector *g_bufferInjector = nil;
static WebRTCCameraAdapter *g_cameraAdapter = nil;

// Componentes de substituição de câmera
static BOOL g_cameraRunning = NO; // Flag que indica se a câmera está ativa
static NSString *g_cameraPosition = @"B"; // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // Orientação do vídeo/foto
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait; // Última orientação para otimização

// Camadas para substituição visual da câmera
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;

// Variáveis para controle dos botões de volume (menu)
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;

// Função para salvar configurações
void saveSettings() {
    if (g_settings) {
        [g_settings setObject:g_serverIP forKey:@"serverIP"];
        [g_settings setBool:g_replacementActive forKey:@"replacementActive"];
        [g_settings synchronize];
        writeLog(@"[WebRTCTweak] Configurações salvas: IP=%@, substituição=%@",
                g_serverIP, g_replacementActive ? @"ativa" : @"inativa");
    }
}

// Função para carregar configurações
void loadSettings() {
    g_settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.vcam.webrtctweak"];
    
    if ([g_settings objectForKey:@"serverIP"]) {
        g_serverIP = [g_settings stringForKey:@"serverIP"];
    }
    
    g_replacementActive = [g_settings boolForKey:@"replacementActive"];
    
    writeLog(@"[WebRTCTweak] Configurações carregadas: IP=%@, substituição=%@",
            g_serverIP, g_replacementActive ? @"ativa" : @"inativa");
}

// Função para iniciar a conexão WebRTC
void startWebRTCConnection() {
    if (!g_webRTCManager) {
        g_webRTCManager = [WebRTCManager sharedInstance];
    }
    
    // Configurar o IP do servidor
    g_webRTCManager.serverIP = g_serverIP;
    
    // Configurar adaptação automática para formato nativo
    g_webRTCManager.autoAdaptToCameraEnabled = YES;
    g_webRTCManager.adaptationMode = WebRTCAdaptationModeCompatibility;
    
    // Iniciar a conexão WebRTC
    [g_webRTCManager startWebRTC];
    
    // Inicializar o adaptador de câmera
    if (!g_cameraAdapter) {
        g_cameraAdapter = [WebRTCCameraAdapter sharedInstance];
    }
    
    // Iniciar o adaptador com o WebRTCManager
    [g_cameraAdapter startWithManager:g_webRTCManager];
    g_cameraAdapter.active = YES;
    
    writeLog(@"[WebRTCTweak] Conexão WebRTC iniciada com servidor: %@", g_serverIP);
}

// Função para parar a conexão WebRTC
void stopWebRTCConnection() {
    // Parar o adaptador de câmera
    if (g_cameraAdapter) {
        [g_cameraAdapter stop];
    }
    
    // Parar o WebRTCManager
    if (g_webRTCManager) {
        [g_webRTCManager stopWebRTC:YES];
        writeLog(@"[WebRTCTweak] Conexão WebRTC interrompida");
    }
}

// Função para ativar a substituição da câmera
void activateReplacement() {
    g_replacementActive = YES;
    
    // Se a câmera estiver rodando, iniciar WebRTC
    if (g_cameraRunning) {
        startWebRTCConnection();
    }
    
    saveSettings();
    writeLog(@"[WebRTCTweak] Substituição da câmera ativada");
}

// Função para desativar a substituição da câmera
void deactivateReplacement() {
    g_replacementActive = NO;
    
    // Parar a conexão WebRTC
    stopWebRTCConnection();
    
    saveSettings();
    writeLog(@"[WebRTCTweak] Substituição da câmera desativada");
}

// Função para obter janela principal do aplicativo
UIWindow* getKeyWindow() {
    writeLog(@"[WebRTCTweak] Buscando janela principal");
    
    UIWindow *keyWindow = nil;
    NSArray *windows = UIApplication.sharedApplication.windows;
    for(UIWindow *window in windows) {
        if(window.isKeyWindow) {
            keyWindow = window;
            writeLog(@"[WebRTCTweak] Janela principal encontrada");
            break;
        }
    }
    return keyWindow;
}

// Função para exibir o menu de configuração
void showConfigMenu() {
    writeLog(@"[WebRTCTweak] Abrindo menu de configuração");
    
    // Determina o status atual para mostrar corretamente no menu
    NSString *statusText = g_replacementActive ? @"Substituição ativa" : @"Substituição inativa";
    NSString *connectionStatus = @"Desconectado";
    
    if (g_webRTCManager && g_webRTCManager.state == WebRTCManagerStateConnected) {
        connectionStatus = g_webRTCManager.isReceivingFrames ? @"Recebendo stream" : @"Conectado, sem stream";
    }
    
    // Cria o alerta para o menu principal
    UIAlertController *alertController = [UIAlertController
        alertControllerWithTitle:@"WebRTC Camera Replacement"
        message:[NSString stringWithFormat:@"Status: %@\nServidor: %@\nConexão: %@",
                statusText, g_serverIP, connectionStatus]
        preferredStyle:UIAlertControllerStyleAlert];
    
    // Ação para configurar o IP do servidor
    UIAlertAction *configIPAction = [UIAlertAction
        actionWithTitle:@"Configurar IP do servidor"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            writeLog(@"[WebRTCTweak] Opção 'Configurar IP' escolhida");
            
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
                        saveSettings();
                        
                        if (g_webRTCManager) {
                            g_webRTCManager.serverIP = g_serverIP;
                        }
                        
                        // Se a substituição estiver ativa, reiniciar a conexão
                        if (g_replacementActive && g_cameraRunning) {
                            stopWebRTCConnection();
                            startWebRTCConnection();
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
                        [[getKeyWindow() rootViewController] presentViewController:confirmAlert animated:YES completion:nil];
                    }
                }];
            
            UIAlertAction *cancelAction = [UIAlertAction
                actionWithTitle:@"Cancelar"
                style:UIAlertActionStyleCancel
                handler:nil];
            
            [ipAlert addAction:saveAction];
            [ipAlert addAction:cancelAction];
            
            [[getKeyWindow() rootViewController] presentViewController:ipAlert animated:YES completion:nil];
        }];
    
    // Ação para ativar/desativar a substituição
    NSString *toggleTitle = g_replacementActive ? @"Desativar substituição" : @"Ativar substituição";
    UIAlertAction *toggleAction = [UIAlertAction
        actionWithTitle:toggleTitle
        style:g_replacementActive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            writeLog(@"[WebRTCTweak] Opção '%@' escolhida", toggleTitle);
            
            if (g_replacementActive) {
                deactivateReplacement();
                
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
                [[getKeyWindow() rootViewController] presentViewController:successAlert animated:YES completion:nil];
            } else {
                activateReplacement();
                
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
                [[getKeyWindow() rootViewController] presentViewController:successAlert animated:YES completion:nil];
            }
        }];
    
    // Ação para ver status detalhado
    UIAlertAction *statusAction = [UIAlertAction
        actionWithTitle:@"Ver status detalhado"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            writeLog(@"[WebRTCTweak] Opção 'Ver status detalhado' escolhida");
            
            // Coleta informações detalhadas de status
            NSMutableString *statusInfo = [NSMutableString string];
            [statusInfo appendFormat:@"Substituição: %@\n", g_replacementActive ? @"Ativa" : @"Inativa"];
            [statusInfo appendFormat:@"Servidor: %@\n", g_serverIP];
            [statusInfo appendFormat:@"Câmera ativa: %@\n", g_cameraRunning ? @"Sim" : @"Não"];
            [statusInfo appendFormat:@"Posição da câmera: %@\n", g_cameraPosition];
            [statusInfo appendFormat:@"Orientação: %d\n", (int)g_photoOrientation];
            
            // Informações de conexão WebRTC
            if (g_webRTCManager) {
                [statusInfo appendFormat:@"Estado WebRTC: %d\n", (int)g_webRTCManager.state];
                [statusInfo appendFormat:@"Recebendo frames: %@\n", g_webRTCManager.isReceivingFrames ? @"Sim" : @"Não"];
                
                // Se tiver conversor de frames, mostrar informações sobre formato
                if (g_webRTCManager.frameConverter) {
                    [statusInfo appendFormat:@"Formato de pixel: %@\n",
                        [WebRTCFrameConverter stringFromPixelFormat:g_webRTCManager.frameConverter.detectedPixelFormat]];
                    [statusInfo appendFormat:@"Modo de processamento: %@\n", g_webRTCManager.frameConverter.processingMode];
                    [statusInfo appendFormat:@"FPS atual: %.1f\n", g_webRTCManager.frameConverter.currentFps];
                }
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
            [[getKeyWindow() rootViewController] presentViewController:statusAlert animated:YES completion:nil];
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
    [[getKeyWindow() rootViewController] presentViewController:alertController animated:YES completion:nil];
}

// * * * * * HOOKS DE SUBSTITUIÇÃO DE CÂMERA * * * * *

// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer {
    writeLog(@"[WebRTCTweak] AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer");
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
        writeLog(@"[WebRTCTweak] DisplayLink criado para atualização contínua");
    }

    // Adiciona camada de preview se ainda não existe
    if (![[self sublayers] containsObject:g_previewLayer]) {
        writeLog(@"[WebRTCTweak] Configurando camadas de preview");
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
            writeLog(@"[WebRTCTweak] Tamanho das camadas inicializado");
        });
    }
}

// Método adicionado para atualização contínua do preview
%new
-(void)step:(CADisplayLink *)sender {
    // Verificar se a substituição está ativa
    if (!g_replacementActive) {
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
    BOOL receivingFrames = (g_webRTCManager && g_webRTCManager.isReceivingFrames);
    
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
            
            // Atualiza a orientação no adaptador de câmera
            if (g_cameraAdapter) {
                [g_cameraAdapter setVideoOrientation:g_photoOrientation];
            }
            
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
            
            // Usa o adaptador de câmera para atualizar a camada de preview
            if (g_cameraAdapter) {
                [g_cameraAdapter updatePreviewLayer:g_previewLayer];
            }
        }
    }
}
%end

// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
// Método chamado quando a câmera é iniciada
-(void) startRunning {
    writeLog(@"[WebRTCTweak] AVCaptureSession::startRunning - Câmera iniciando");
    g_cameraRunning = YES;
    
    %orig;
    
    // Se a substituição estiver ativa, iniciar a conexão WebRTC
    if (g_replacementActive) {
        startWebRTCConnection();
    }
    
    writeLog(@"[WebRTCTweak] Câmera iniciada");
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    writeLog(@"[WebRTCTweak] AVCaptureSession::stopRunning - Câmera parando");
    g_cameraRunning = NO;
    
    %orig;
    
    // Se a substituição estiver ativa, parar a conexão WebRTC
    if (g_replacementActive) {
        stopWebRTCConnection();
    }
    
    writeLog(@"[WebRTCTweak] Câmera parada");
}

// Método chamado quando um dispositivo de entrada é adicionado à sessão
- (void)addInput:(AVCaptureDeviceInput *)input {
    writeLog(@"[WebRTCTweak] AVCaptureSession::addInput - Adicionando dispositivo");
    
    // Determina qual câmera está sendo usada (frontal ou traseira)
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
        writeLog(@"[WebRTCTweak] Posição da câmera definida como: %@", g_cameraPosition);
    }
    
    %orig;
}

%end

// Hook para intercepção do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    writeLog(@"[WebRTCTweak] AVCaptureVideoDataOutput::setSampleBufferDelegate - Configurando delegate");
    
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        writeLog(@"[WebRTCTweak] Delegate ou queue nulos, chamando método original sem modificações");
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
        writeLog(@"[WebRTCTweak] Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;

        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Armazena a orientação atual do vídeo
                g_photoOrientation = [connection videoOrientation];
                
                // Atualiza a orientação no adaptador de câmera
                if (g_cameraAdapter) {
                    [g_cameraAdapter setVideoOrientation:g_photoOrientation];
                    
                    // Atualiza o status de espelhamento com base na conexão
                    if ([connection isVideoMirrored]) {
                        [g_cameraAdapter setVideoMirrored:YES];
                    }
                }
                
                // Verifica se a substituição está ativa e se temos um adaptador configurado
                if (g_replacementActive && g_cameraAdapter) {
                    // Usa o adaptador para obter um frame adaptado
                    CMSampleBufferRef webrtcBuffer = [g_cameraAdapter getAdaptedFrameForOriginal:sampleBuffer];
                    
                    // Atualiza o preview usando o buffer
                    if (webrtcBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                        [g_previewLayer flush];
                        [g_previewLayer enqueueSampleBuffer:webrtcBuffer];
                    }
                    
                    // Chamada do método original com o buffer substituído ou o original se a substituição falhar
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                          output, webrtcBuffer != nil ? webrtcBuffer : sampleBuffer, connection);
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
        writeLog(@"[WebRTCTweak] Sequência volume-up + volume-down detectada, abrindo menu");
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
    writeLog(@"--------------------------------------------------");
    writeLog(@"[WebRTCTweak] Inicializando tweak");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        writeLog(@"[WebRTCTweak] Detectado iOS 13 ou superior, inicializando hooks para VolumeControl");
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Carregar configurações
    loadSettings();
    
    // Se a substituição estiver ativa e a câmera estiver rodando, iniciar WebRTC
    if (g_replacementActive && g_cameraRunning) {
        startWebRTCConnection();
    }
    
    writeLog(@"[WebRTCTweak] Processo atual: %@", [NSProcessInfo processInfo].processName);
    writeLog(@"[WebRTCTweak] Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    writeLog(@"[WebRTCTweak] Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor {
    writeLog(@"[WebRTCTweak] Finalizando tweak");
    
    // Desativa a substituição e para a conexão WebRTC
    if (g_replacementActive) {
        stopWebRTCConnection();
    }
    
    // Limpa o adaptador de câmera
    if (g_cameraAdapter) {
        [g_cameraAdapter stop];
        g_cameraAdapter = nil;
    }
    
    // Parar e limpar o WebRTCManager
    if (g_webRTCManager) {
        [g_webRTCManager stopWebRTC:YES];
        g_webRTCManager = nil;
    }
    
    // Limpar o buffer injector
    g_bufferInjector = nil;
    
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
    g_replacementActive = NO;
    
    // Salvar configurações finais
    saveSettings();
    
    writeLog(@"[WebRTCTweak] Tweak finalizado com sucesso");
    writeLog(@"--------------------------------------------------");
}
