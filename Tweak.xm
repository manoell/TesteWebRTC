#import "FloatingWindow.h"
#import <UIKit/UIKit.h>
#import "logger.h"

static FloatingWindow *floatingWindow;

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    setLogLevel(5);
    writeLog(@"Tweak carregado em SpringBoard");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        CGRect windowFrame = CGRectMake(20, 60, 200, 300);
        floatingWindow = [[FloatingWindow alloc] initWithFrame:windowFrame];
        [floatingWindow show];
        writeLog(@"Janela flutuante exibida");
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
