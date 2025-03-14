#import "logger.h"

static int gLogLevel = 3;

void setLogLevel(int level) {
    gLogLevel = level;
}

void writeLog(NSString *format, ...) {
    if (gLogLevel <= 0) return;
    
    @try {
        va_list args;
        va_start(args, format);
        NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n",
                              [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle],
                              formattedString];
        
        NSLog(@"[WebRTCTweak] %@", formattedString);
        
        if (gLogLevel >= 4) {
            NSString *logPath = @"/var/tmp/testeWebRTC.log";
            
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (fileHandle == nil) {
                [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
                if (fileHandle == nil) {
                    return;
                }
            }
            
            @try {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
                [fileHandle closeFile];
            } @catch (NSException *e) {
                NSLog(@"[WebRTCTweak] Erro ao escrever log: %@", e);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[WebRTCTweak] ERRO NO LOGGER: %@", e);
    }
}
