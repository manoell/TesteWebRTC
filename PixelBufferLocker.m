#import "PixelBufferLocker.h"
#import "WebRTCFrameConverter.h"
#import "logger.h"

@implementation PixelBufferLocker

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          converter:(WebRTCFrameConverter *)converter {
    self = [super init];
    if (self) {
        _pixelBuffer = pixelBuffer;
        _converter = converter;
        _locked = NO;
    }
    return self;
}

- (BOOL)lock {
    if (!_locked && _pixelBuffer) {
        CVReturn result = CVPixelBufferLockBaseAddress(_pixelBuffer, kCVPixelBufferLock_ReadOnly);
        if (result == kCVReturnSuccess) {
            _locked = YES;
            if (_converter) {
                // Usando método seguro para incrementar contador
                [_converter performSelector:@selector(incrementPixelBufferLockCount)];
            }
            return YES;
        } else {
            writeErrorLog(@"[PixelBufferLocker] Falha ao bloquear CVPixelBuffer: %d", (int)result);
        }
    }
    return NO;
}

- (void)unlock {
    if (_locked && _pixelBuffer) {
        CVPixelBufferUnlockBaseAddress(_pixelBuffer, kCVPixelBufferLock_ReadOnly);
        _locked = NO;
        if (_converter) {
            // Usando método seguro para incrementar contador
            [_converter performSelector:@selector(incrementPixelBufferUnlockCount)];
        }
    }
}

- (void)dealloc {
    // Garantir desbloqueio ao liberar o objeto
    [self unlock];
}

@end
