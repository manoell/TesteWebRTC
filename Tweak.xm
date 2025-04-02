#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WebRTCManager.h"
#import "Logger.h"

// Variáveis globais para gerenciamento de recursos
static BOOL g_webrtcActive = NO;                           // Flag que indica se substituição por WebRTC está ativa
static NSString *g_serverIP = @"192.168.0.178";            // IP padrão do servidor WebRTC
static AVSampleBufferDisplayLayer *g_previewLayer = nil;   // Layer para visualização da câmera
static BOOL g_cameraRunning = NO;                          // Flag que indica se a câmera está ativa
static NSString *g_cameraPosition = @"B";                  // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // Orientação do vídeo/foto
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait; // Última orientação para otimização

// Variáveis para detecção de combinação de botões de volume
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;

// Camada para cobrir visualização original da câmera
static CALayer *g_maskLayer = nil;

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

// Função para mostrar o menu de configuração simplificado
static void showConfigMenu() {
    vcam_log(@"Abrindo menu de configuração simplificado");
    
    WebRTCManager *webRTCManager = [WebRTCManager sharedInstance];
    
    // Determina o status atual
    NSString *statusText = g_webrtcActive ? @"Ativado" : @"Desativado";
    
    // Cria o alerta para o menu simplificado
    UIAlertController *alertController = [UIAlertController
        alertControllerWithTitle:@"WebRTC Camera"
        message:[NSString stringWithFormat:@"Status: %@", statusText]
        preferredStyle:UIAlertControllerStyleAlert];
    
    // Campo para o IP do servidor
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Endereço IP do servidor";
        textField.text = g_serverIP;
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    
    // Ação para ativar/desativar a substituição
    NSString *toggleTitle = g_webrtcActive ? @"Desativar" : @"Ativar";
    UIAlertAction *toggleAction = [UIAlertAction
        actionWithTitle:toggleTitle
        style:g_webrtcActive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            vcam_log(@"Botão de alternar substituição pressionado");
            
            // Atualizar o IP do servidor com o valor do campo de texto
            NSString *newIP = alertController.textFields.firstObject.text;
            if (newIP && newIP.length > 0) {
                g_serverIP = newIP;
                webRTCManager.serverIP = newIP;
            }
            
            // Alternar estado ativo
            g_webrtcActive = !g_webrtcActive;
            
            if (g_webrtcActive) {
                // Ativar WebRTC
                [webRTCManager startWebRTC];
                
                // Avisa o usuário que a substituição foi ativada
                UIAlertController *successAlert = [UIAlertController
                    alertControllerWithTitle:@"Sucesso"
                    message:@"Substituição de câmera ativada."
                    preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction *okAction = [UIAlertAction
                    actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:nil];
                
                [successAlert addAction:okAction];
                [getKeyWindow().rootViewController presentViewController:successAlert animated:YES completion:nil];
            } else {
                // Desativar WebRTC
                [webRTCManager stopWebRTC];
                
                // Avisa o usuário que a substituição foi desativada
                UIAlertController *successAlert = [UIAlertController
                    alertControllerWithTitle:@"Sucesso"
                    message:@"Substituição de câmera desativada."
                    preferredStyle:UIAlertControllerStyleAlert];
                
                UIAlertAction *okAction = [UIAlertAction
                    actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:nil];
                
                [successAlert addAction:okAction];
                [getKeyWindow().rootViewController presentViewController:successAlert animated:YES completion:nil];
            }
        }];
    
    // Ação para cancelar
    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:@"Cancelar"
        style:UIAlertActionStyleCancel
        handler:nil];
    
    // Adiciona as ações ao alerta
    [alertController addAction:toggleAction];
    [alertController addAction:cancelAction];
    
    // Apresenta o alerta
    [getKeyWindow().rootViewController presentViewController:alertController animated:YES completion:nil];
}

// Agrupa os hooks relativos à câmera
%group CameraHooks
// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer{
    vcam_log(@"AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer");
    %orig;

    // Configura display link para atualização contínua
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        displayLink.preferredFramesPerSecond = 30;
        
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
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
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
    
    // Se WebRTC está ativo, mostrar camada preta
    WebRTCManager *manager = [WebRTCManager sharedInstance];
    
    // Mostrar a camada preta sempre que WebRTC estiver ativo
    if (g_maskLayer != nil) {
        g_maskLayer.opacity = 1.0;
    }
    
    // Se estiver recebendo frames, mostrar a camada de preview
    if (manager.isReceivingFrames) {
        if (g_previewLayer != nil) {
            g_previewLayer.opacity = 1.0;
            [g_previewLayer setVideoGravity:[self videoGravity]];
        }
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
        vcam_log(@"WebRTC ativo, iniciando conexão");
        WebRTCManager *manager = [WebRTCManager sharedInstance];
        manager.serverIP = g_serverIP;
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
%end // Fim do grupo CameraHooks

// Agrupa os hooks relativos aos botões de volume
%group VolumeHooks
// Hook para os controles de volume
%hook VolumeControl
// Método chamado quando volume é aumentado
-(void)increaseVolume {
    vcam_log(@"VolumeControl::increaseVolume - Botão volume+ pressionado");
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Salva o timestamp atual
    g_volume_up_time = nowtime;
    
    // Chama o método original
    %orig;
}

// Método chamado quando volume é diminuído
-(void)decreaseVolume {
    vcam_log(@"VolumeControl::decreaseVolume - Botão volume- pressionado");
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
%end // Fim do grupo VolumeHooks

// Função chamada quando o tweak é carregado
%ctor {
    vcam_log(@"--------------------------------------------------");
    vcam_log(@"WebRTCCamera - Inicializando tweak");
    
    NSString *processName = [NSProcessInfo processInfo].processName;
    vcam_logf(@"Processo atual: %@", processName);
    
    // Verifica se é o SpringBoard para carregar apenas os hooks necessários
    if ([processName isEqualToString:@"SpringBoard"]) {
        vcam_log(@"Executando no SpringBoard, inicializando hooks para controles de volume");
        
        // No iOS 13+, a classe é SBVolumeControl
        Class volumeControlClass = NSClassFromString(@"SBVolumeControl");
        if (volumeControlClass) {
            %init(VolumeHooks, VolumeControl = volumeControlClass);
            vcam_log(@"Hooks para SBVolumeControl inicializados com sucesso");
        } else {
            vcam_log(@"ERRO: Classe SBVolumeControl não encontrada");
        }
    } else {
        // Em outros aplicativos, inicializa os hooks de câmera
        vcam_log(@"Executando em app normal, inicializando hooks para câmera");
        %init(CameraHooks);
    }
    
    vcam_logf(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    vcam_log(@"Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor {
    vcam_log(@"WebRTCCamera - Finalizando tweak");
    
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
    
    vcam_log(@"Tweak finalizado com sucesso");
    vcam_log(@"--------------------------------------------------");
}
