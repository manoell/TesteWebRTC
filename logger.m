#import "Logger.h"

// Função para registrar logs no arquivo
void vcam_log(NSString *message) {
    static dispatch_queue_t logQueue = nil;
    static NSDateFormatter *dateFormatter = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        // Cria uma fila dedicada para operações de log
        logQueue = dispatch_queue_create("com.vcam.log", DISPATCH_QUEUE_SERIAL);
        
        // Inicializa o formatador de data
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    });
    
    dispatch_async(logQueue, ^{
        // Obtém a data e hora atual
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
        
        // Formata a mensagem de log com timestamp
        NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        // Caminho para o arquivo de log
        NSString *logPath = @"/tmp/vcam_debug.log";
        
        // Verifica se o arquivo existe, se não, cria-o
        if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
            [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        
        // Abre o arquivo em modo de anexação
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        }
        
        // Também exibe no console para facilitar diagnóstico
        NSLog(@"[WebRTCCamera] %@", message);
    });
}

// Função para registrar logs com formato, semelhante a NSLog
void vcam_logf(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    // Usa a função vcam_log para registrar a mensagem formatada
    vcam_log(message);
}
