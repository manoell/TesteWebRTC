#import "logger.h"

// Nível de log global, default é 3 (avisos e erros)
static int gLogLevel = 3;

// Caminho do arquivo de log
static NSString *gLogPath = @"/var/tmp/testeWebRTC.log";

// Lock para acesso ao arquivo (thread safety)
static NSLock *gLogLock = nil;

// Limite de tamanho do arquivo de log em bytes (5MB)
static const long long MAX_LOG_SIZE = 5 * 1024 * 1024;

// Inicialização
__attribute__((constructor))
static void initialize() {
    gLogLock = [[NSLock alloc] init];
}

void setLogLevel(int level) {
    if (level >= 0 && level <= 5) {
        gLogLevel = level;
    }
}

int getLogLevel(void) {
    return gLogLevel;
}

void setLogPath(NSString *path) {
    if (path && path.length > 0) {
        gLogPath = [path copy];
    }
}

void clearLogFile(void) {
    if (gLogLevel >= 4) {
        [gLogLock lock];
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [gLogLock unlock];
    }
}

// Verifica se o arquivo de log excede o tamanho máximo
static void checkLogFileSize() {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:gLogPath error:&error];
    
    if (!error) {
        NSNumber *fileSize = [attributes objectForKey:NSFileSize];
        
        // Se o arquivo exceder o tamanho máximo, trunca para metade
        if ([fileSize longLongValue] > MAX_LOG_SIZE) {
            NSData *fileData = [NSData dataWithContentsOfFile:gLogPath];
            if (fileData) {
                long long halfSize = [fileSize longLongValue] / 2;
                NSData *truncatedData = [fileData subdataWithRange:NSMakeRange([fileSize longLongValue] - halfSize, halfSize)];
                [truncatedData writeToFile:gLogPath atomically:YES];
            }
        }
    }
}

void writeLog(NSString *format, ...) {
    if (gLogLevel <= 0) return;
    
    @try {
        va_list args;
        va_start(args, format);
        NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        // Adicionar timestamp e identificador
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
        
        // Incluir thread ID para ajudar na depuração
        NSString *threadIdentifier = [NSString stringWithFormat:@"%p", [NSThread currentThread]];
        
        NSString *logMessage = [NSString stringWithFormat:@"[%@][%@] %@\n",
                              timestamp,
                              threadIdentifier,
                              formattedString];
        
        // Log no console para todos os níveis
        NSLog(@"[WebRTCTweak] %@", formattedString);
        
        // Log em arquivo apenas para níveis 4 e 5
        if (gLogLevel >= 4) {
            [gLogLock lock];
            
            @try {
                // Verificar se o diretório existe
                NSString *directory = [gLogPath stringByDeletingLastPathComponent];
                NSFileManager *fileManager = [NSFileManager defaultManager];
                
                NSError *dirError = nil;
                if (![fileManager fileExistsAtPath:directory]) {
                    [fileManager createDirectoryAtPath:directory
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:&dirError];
                    if (dirError) {
                        NSLog(@"[WebRTCTweak] Erro ao criar diretório de log: %@", dirError);
                    }
                }
                
                // Criar arquivo se não existir
                if (![fileManager fileExistsAtPath:gLogPath]) {
                    [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
                
                // Verificar tamanho do arquivo e truncar se necessário
                checkLogFileSize();
                
                // Abrir arquivo para escrita
                NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
                if (fileHandle == nil) {
                    NSLog(@"[WebRTCTweak] Erro ao abrir arquivo de log");
                    [gLogLock unlock];
                    return;
                }
                
                @try {
                    [fileHandle seekToEndOfFile];
                    [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
                    [fileHandle closeFile];
                } @catch (NSException *e) {
                    NSLog(@"[WebRTCTweak] Erro ao escrever log: %@", e);
                }
            } @finally {
                [gLogLock unlock];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[WebRTCTweak] ERRO NO LOGGER: %@", e);
    }
}
