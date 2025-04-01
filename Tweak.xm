#import "WebRTCManager.h"
#import "Logger.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Configurações globais
static NSString *g_serverIP = @"192.168.0.178"; // IP padrão do servidor
static BOOL g_replacementActive = NO; // Flag para controlar se a substituição está ativa
static NSUserDefaults *g_settings = nil; // Para armazenar configurações

// Componente WebRTC
static WebRTCManager *g_webRTCManager = nil;

// Componentes de visualização
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;

// Variáveis para controle dos botões de volume (menu)
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;

// Funções de gestão de configurações
void saveSettings() {
    if (g_settings) {
        [g_settings setObject:g_serverIP forKey:@"serverIP"];
        [g_settings setBool:g_replacementActive forKey:@"replacementActive"];
        [g_settings synchronize];
        writeLog(@"Configurações salvas: IP=%@, substituição=%@",
                g_serverIP, g_replacementActive ? @"ativa" : @"inativa");
    }
}

void loadSettings() {
    g_settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.webcam.rtctweak"];
    
    if ([g_settings objectForKey:@"serverIP"]) {
        g_serverIP = [g_settings stringForKey:@"serverIP"];
    }
    
    g_replacementActive = [g_settings boolForKey:@"replacementActive"];
    
    writeLog(@"Configurações carregadas: IP=%@, substituição=%@",
            g_serverIP, g_replacementActive ? @"ativa" : @"inativa");
}

// Função para mostrar menu de configuração
void showConfigMenu() {
    writeLog(@"Abrindo menu de configuração");
    
    // Determina o status atual para mostrar corretamente no menu
    NSString *statusText = g_replacementActive ? @"Substituição ativa" : @"Substituição inativa";
    
    // Cria o alerta para o menu principal
    UIAlertController *alertController = [UIAlertController
        alertControllerWithTitle:@"WebRTC Camera"
        message:[NSString stringWithFormat:@"Status: %@\nServidor: %@",
                statusText, g_serverIP]
        preferredStyle:UIAlertControllerStyleAlert];
    
    // Ação para configurar o IP do servidor
    UIAlertAction *configIPAction = [UIAlertAction
        actionWithTitle:@"Configurar IP do servidor"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
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
                        [[UIApplication sharedApplication].keyWindow.rootViewController
                            presentViewController:confirmAlert animated:YES completion:nil];
                    }
                }];
            
            UIAlertAction *cancelAction = [UIAlertAction
                actionWithTitle:@"Cancelar"
                style:UIAlertActionStyleCancel
                handler:nil];
            
            [ipAlert addAction:saveAction];
            [ipAlert addAction:cancelAction];
            
            [[UIApplication sharedApplication].keyWindow.rootViewController
                presentViewController:ipAlert animated:YES completion:nil];
        }];
    
    // Ação para ativar/desativar a substituição
    NSString *toggleTitle = g_replacementActive ? @"Desativar substituição" : @"Ativar substituição";
    UIAlertAction *toggleAction = [UIAlertAction
        actionWithTitle:toggleTitle
        style:g_replacementActive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            g_replacementActive = !g_replacementActive;
            saveSettings();
            
            if (g_replacementActive) {
                // Iniciar WebRTC se a câmera estiver ativa
                if (g_webRTCManager == nil) {
                    g_webRTCManager = [[WebRTCManager alloc] initWithServerIP:g_serverIP];
                }
                [g_webRTCManager startWebRTC];
            } else {
                // Parar WebRTC
                if (g_webRTCManager) {
                    [g_webRTCManager stopWebRTC];
                }
            }
            
            // Avisa o usuário sobre a mudança
            UIAlertController *successAlert = [UIAlertController
                alertControllerWithTitle:@"Sucesso"
                message:g_replacementActive ?
                    @"A substituição da câmera foi ativada." :
                    @"A substituição da câmera foi desativada."
                preferredStyle:UIAlertControllerStyleAlert];
            
            UIAlertAction *okAction = [UIAlertAction
                actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault
                handler:nil];
            
            [successAlert addAction:okAction];
            [[UIApplication sharedApplication].keyWindow.rootViewController
                presentViewController:successAlert animated:YES completion:nil];
        }];
    
    // Ação para fechar o menu
    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:@"Fechar"
        style:UIAlertActionStyleCancel
        handler:nil];
    
    // Adicionar ações ao alerta
    [alertController addAction:configIPAction];
    [alertController addAction:toggleAction];
    [alertController addAction:cancelAction];
    
    // Apresentar o alerta
    [[UIApplication sharedApplication].keyWindow.rootViewController
        presentViewController:alertController animated:YES completion:nil];
}

// HOOKS

%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer {
    %orig;

    // Configura camadas para substituição de preview
    if (![[self sublayers] containsObject:g_previewLayer]) {
        writeLog(@"Configurando camadas de preview");
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // Máscara preta para cobrir a visualização original
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        g_maskLayer.opacity = 0; // Começa invisível
        
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        g_previewLayer.opacity = 0; // Começa invisível

        // Inicializa tamanho das camadas
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
        });
    }
}

// Método para atualização contínua do preview
%new
-(void)updatePreview {
    // Verificar se a substituição está ativa
    if (!g_replacementActive) {
        // Esconder as camadas se estiverem visíveis
        if (g_maskLayer != nil && g_maskLayer.opacity > 0.0) {
            g_maskLayer.opacity = 0.0;
        }
        if (g_previewLayer != nil && g_previewLayer.opacity > 0.0) {
            g_previewLayer.opacity = 0.0;
        }
        return;
    }
    
    // Verificar se está recebendo frames WebRTC
    BOOL receivingFrames = (g_webRTCManager && g_webRTCManager.isReceivingFrames);
    
    if (receivingFrames) {
        // Mostrar camadas substitutas
        g_maskLayer.opacity = 1.0;
        g_previewLayer.opacity = 1.0;
        
        // Atualizar tamanho da camada
        g_previewLayer.frame = self.bounds;
        g_maskLayer.frame = self.bounds;
        
        // Atualizar frame de vídeo
        CMSampleBufferRef sampleBuffer = [g_webRTCManager getLatestVideoSampleBuffer];
        if (sampleBuffer && g_previewLayer.readyForMoreMediaData) {
            [g_previewLayer enqueueSampleBuffer:sampleBuffer];
            CFRelease(sampleBuffer);
        }
    } else {
        // Esconder camadas se não estiver recebendo frames
        g_maskLayer.opacity = 0.0;
        g_previewLayer.opacity = 0.0;
    }
}
%end

// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
// Método chamado quando a câmera é iniciada
-(void) startRunning {
    %orig;
    
    writeLog(@"Câmera iniciando");
    
    // Se a substituição estiver ativa, iniciar WebRTC
    if (g_replacementActive) {
        if (g_webRTCManager == nil) {
            g_webRTCManager = [[WebRTCManager alloc] initWithServerIP:g_serverIP];
        }
        [g_webRTCManager startWebRTC];
    }
    
    // Iniciar timer para atualizar preview
    dispatch_async(dispatch_get_main_queue(), ^{
        CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:[NSClassFromString(@"AVCaptureVideoPreviewLayer") new]
                                                                 selector:@selector(updatePreview)];
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    });
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    %orig;
    
    writeLog(@"Câmera parando");
    
    // Parar WebRTC se estiver ativo
    if (g_webRTCManager) {
        [g_webRTCManager stopWebRTC];
    }
}
%end

// Hook para os botões de volume (acesso ao menu)
%hook VolumeControl
// Método chamado quando volume é aumentado
-(void)increaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    g_volume_up_time = nowtime;
    %orig;
}

// Método chamado quando volume é diminuído
-(void)decreaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Verificar se o botão de aumentar volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 1) {
        writeLog(@"Sequência volume-up + volume-down detectada, abrindo menu");
        showConfigMenu();
    }
    
    g_volume_down_time = nowtime;
    %orig;
}
%end

// Função chamada quando o tweak é carregado
%ctor {
    writeLog(@"--------------------------------------------------");
    writeLog(@"Inicializando WebRTC Camera Tweak");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        writeLog(@"Detectado iOS 13 ou superior, inicializando hooks para VolumeControl");
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Carregar configurações
    loadSettings();
    
    writeLog(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    writeLog(@"Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor {
    writeLog(@"Finalizando tweak");
    
    // Desativar WebRTC
    if (g_webRTCManager) {
        [g_webRTCManager stopWebRTC];
        g_webRTCManager = nil;
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
    
    // Salvar configurações finais
    saveSettings();
    
    writeLog(@"Tweak finalizado com sucesso");
    writeLog(@"--------------------------------------------------");
}
