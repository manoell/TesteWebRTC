#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "WebRTCBufferInjector.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"

static FloatingWindow *floatingWindow;
static BOOL enableCameraReplacement = YES; // Flag para controlar substituição de câmera

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    
    // Configurar nível de log para máximo durante testes
    setLogLevel(5);
    writeLog(@"Tweak carregado em SpringBoard");
    
    // Inicializar com delay para garantir que o sistema esteja pronto
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        // Limpar log antigo antes de iniciar nova sessão
        clearLogFile();
        
        // Criar a janela flutuante
        floatingWindow = [[FloatingWindow alloc] init];
        
        // Inicializar o WebRTCManager e atribuí-lo à janela
        WebRTCManager *manager = [WebRTCManager sharedInstance];
        floatingWindow.webRTCManager = manager;
        
        // Configurar para adaptação automática ao formato da câmera
        manager.autoAdaptToCameraEnabled = YES;
        manager.adaptationMode = WebRTCAdaptationModeCompatibility;
        
        // Mostrar a janela após um pequeno delay para garantir inicialização completa
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [floatingWindow show];
            writeLog(@"Janela flutuante exibida em modo minimizado");
        });
    });
}

%end

%hook AVCaptureSession

- (void)startRunning {
    writeLog(@"[WebRTCHook] AVCaptureSession startRunning interceptado");
    
    // Executar o método original primeiro para garantir que a câmera inicialize
    %orig;
    
    // Se o WebRTCManager não estiver pronto, não tente configurar a substituição
    WebRTCManager *manager = [WebRTCManager sharedInstance];
    if (!manager) {
        writeLog(@"[WebRTCHook] WebRTCManager não está disponível, pulando configuração");
        return;
    }
    
    // Configurar e ativar a substituição se estiver habilitada
    WebRTCBufferInjector *injector = [WebRTCBufferInjector sharedInstance];
    if (!injector.isConfigured) {
        [injector configureWithSession:self];
        writeLog(@"[WebRTCHook] WebRTCBufferInjector configurado para a sessão");
    }
    
    // Após a inicialização original da sessão, ativar a substituição
    // Importante: usar dispatch_async para evitar deadlocks
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WebRTCBufferInjector sharedInstance] activateInjection];
    });
}

- (void)stopRunning {
    writeLog(@"[WebRTCHook] AVCaptureSession stopRunning interceptado");
    
    // Desativar a substituição antes de parar a sessão
    [[WebRTCBufferInjector sharedInstance] deactivateInjection];
    
    // Executar o método original
    %orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    writeLog(@"[WebRTCHook] setSampleBufferDelegate: %@", delegate);
    
    // Registrar o delegate original para referência
    WebRTCBufferInjector *injector = [WebRTCBufferInjector sharedInstance];
    [injector registerOriginalDelegate:delegate queue:queue];
    
    // Verificar se devemos substituir o delegate
    if ([injector isActive]) {
        // Se a substituição estiver ativa, definir nosso injector como delegate
        %orig(injector, queue);
        writeLog(@"[WebRTCHook] Delegate substituído por WebRTCBufferInjector");
    } else {
        // Caso contrário, usar o delegate original
        %orig;
    }
}

%end

%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    writeLog(@"[WebRTCHook] setVideoOrientation: %d", (int)videoOrientation);
    
    // Informar o WebRTCManager sobre a mudança de orientação
    WebRTCManager *manager = [WebRTCManager sharedInstance];
    if (manager) {
        [manager adaptOutputToVideoOrientation:(int)videoOrientation];
    }
    
    %orig;
}

- (void)setVideoMirrored:(BOOL)videoMirrored {
    writeLog(@"[WebRTCHook] setVideoMirrored: %d", videoMirrored);
    
    // Informar o WebRTCManager sobre o espelhamento
    WebRTCManager *manager = [WebRTCManager sharedInstance];
    if (manager) {
        [manager setVideoMirrored:videoMirrored];
    }
    
    %orig;
}

%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    
    // Parar preview e liberar recursos
    if (floatingWindow) {
        [floatingWindow hide];
        if (floatingWindow.webRTCManager) {
            [floatingWindow.webRTCManager stopWebRTC:YES];
        }
    }
    
    // Desativar injeção de buffer se estiver ativa
    WebRTCBufferInjector *injector = [WebRTCBufferInjector sharedInstance];
    if (injector.isActive) {
        [injector deactivateInjection];
    }
    
    // Liberar referência
    floatingWindow = nil;
}
