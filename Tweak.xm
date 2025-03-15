#import "FloatingWindow.h"
#import <UIKit/UIKit.h>
#import "logger.h"

static FloatingWindow *floatingWindow;

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    
    // Configurar nível de log para máximo durante testes
    setLogLevel(5);
    writeLog(@"Tweak carregado em SpringBoard");
    
    // Inicializar a janela flutuante no thread principal
    dispatch_async(dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        // Criar janela com tamanho para tela cheia primeiro
        // Será redimensionada para AssistiveTouch após setState
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGRect windowFrame = CGRectMake(
            screenBounds.size.width - 70,  // Posicionar na direita
            screenBounds.size.height / 2 - 25, // Centro vertical
            50, // Tamanho da bolinha
            50  // Tamanho da bolinha
        );
        
        floatingWindow = [[FloatingWindow alloc] initWithFrame:windowFrame];
        
        // É crucial definir o estado ANTES de mostrar
        // Isso aplica as configurações de AssistiveTouch
        floatingWindow.windowState = FloatingWindowStateMinimized;
        
        // Mostrar a janela
        [floatingWindow show];
        writeLog(@"Janela flutuante exibida em modo minimizado");
    });
}

%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    [floatingWindow hide];
    floatingWindow = nil;
}
