#import "Logger.h"
#import <UIKit/UIKit.h>

// Caminho do arquivo de log
static NSString *gLogPath = @"/tmp/webrtc_camera.log";

// Lock para acesso ao arquivo (thread safety)
static NSLock *gLogLock = nil;

// Inicialização
__attribute__((constructor))
static void initialize() {
    gLogLock = [[NSLock alloc] init];
    
    // Criar cabeçalho de início de sessão
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    
    UIDevice *device = [UIDevice currentDevice];
    NSString *sessionHeader = [NSString stringWithFormat:
                              @"\n\n=== NOVA SESSÃO - %@ ===\n"
                              @"Device: %@ (%@)\n"
                              @"iOS: %@\n"
                              @"=================================\n\n",
                              [formatter stringFromDate:[NSDate date]],
                              device.model,
                              device.systemName,
                              device.systemVersion];
    
    // Escrever cabeçalho se o arquivo de log existir, ou criá-lo
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL fileExists = [fileManager fileExistsAtPath:gLogPath];
    
    if (fileExists) {
        [gLogLock lock];
        @try {
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[sessionHeader dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } @catch (NSException *e) {
            NSLog(@"[WebRTCTweak] Erro ao inicializar log: %@", e);
        } @finally {
            [gLogLock unlock];
        }
    } else {
        // Criar novo arquivo com cabeçalho
        [sessionHeader writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// Função interna para escrita de log
static void writeLogInternal(NSString *prefix, NSString *message) {
    if (!message) return;
    
    // Adicionar timestamp
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    
    // Incluir thread ID para ajudar na depuração
    NSString *threadIdentifier = [NSString stringWithFormat:@"%p", [NSThread currentThread]];
    
    NSString *logMessage = [NSString stringWithFormat:@"[%@][%@]%@ %@\n",
                          timestamp,
                          threadIdentifier,
                          prefix,
                          message];
    
    // Log no console
    NSLog(@"[WebRTCTweak]%@ %@", prefix, message);
    
    // Log em arquivo
    [gLogLock lock];
    @try {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } else {
            // Tentar criar o arquivo se não existir
            [logMessage writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {
        NSLog(@"[WebRTCTweak] Erro ao escrever log: %@", e);
    } @finally {
        [gLogLock unlock];
    }
}

void writeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    writeLogInternal(@"[INFO]", message);
}

void writeErrorLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    writeLogInternal(@"[ERROR]", message);
}
