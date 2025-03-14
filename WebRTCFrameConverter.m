#import "WebRTCFrameConverter.h"
#import "logger.h"

@implementation WebRTCFrameConverter {
    RTCVideoFrame *_lastFrame;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _processingQueue;
    BOOL _isReceivingFrames;
    int _frameCount;
    NSTimeInterval _lastFrameTime;
    CFTimeInterval _maxFrameRate;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing", DISPATCH_QUEUE_SERIAL);
        _isReceivingFrames = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _maxFrameRate = 1.0 / 30.0; // 30 fps máximo
        writeLog(@"[WebRTCFrameConverter] Inicializado");
    }
    return self;
}

- (void)dealloc {
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
}

- (BOOL)isReceivingFrames {
    return _isReceivingFrames;
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
    writeLog(@"[WebRTCFrameConverter] setSize chamado: %@", NSStringFromCGSize(size));
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    // Limitar a taxa de frames processados
    NSTimeInterval currentTime = CACurrentMediaTime();
    NSTimeInterval elapsed = currentTime - _lastFrameTime;
    
    if (elapsed < _maxFrameRate && _frameCount > 1) {
        // Pulando frames para manter a taxa desejada
        return;
    }
    
    _lastFrameTime = currentTime;
    
    // Thread safety
    @synchronized(self) {
        _frameCount++;
        _isReceivingFrames = YES;
        _lastFrame = frame;
    }
    
    if (_frameCount == 1 || _frameCount % 30 == 0) {
        writeLog(@"[WebRTCFrameConverter] renderFrame #%d recebido: %dx%d",
                _frameCount,
                (int)frame.width,
                (int)frame.height);
        
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        writeLog(@"[WebRTCFrameConverter] Tipo do buffer: %@", NSStringFromClass([buffer class]));
    }
    
    // Processamento no thread principal ou em background
    if (!self.frameCallback) {
        return;
    }
    
    // Processamento em thread separada
    dispatch_async(_processingQueue, ^{
        @try {
            UIImage *image = [self imageFromVideoFrame:frame];
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.frameCallback(image);
                });
            }
        } @catch (NSException *exception) {
            writeLog(@"[WebRTCFrameConverter] Exceção ao processar frame: %@", exception);
        }
    });
}

- (void)setRenderFrame:(RTCVideoFrame *)frame {
    [self renderFrame:frame];
}

- (UIImage *)imageFromVideoFrame:(RTCVideoFrame *)frame {
    @try {
        if (!frame) {
            return nil;
        }
        
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        
        // Método para RTCCVPixelBuffer
        if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
            CVPixelBufferRef cvPixelBuffer = pixelBuffer.pixelBuffer;
            
            if (!cvPixelBuffer) {
                return nil;
            }
            
            // Usar um tratamento mais seguro com autoreleasepool
            @autoreleasepool {
                // Bloquear o buffer para acesso
                CVReturn lockResult = CVPixelBufferLockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                if (lockResult != kCVReturnSuccess) {
                    writeLog(@"[WebRTCFrameConverter] Falha ao bloquear CVPixelBuffer: %d", (int)lockResult);
                    return nil;
                }
                
                CIImage *ciImage = [CIImage imageWithCVPixelBuffer:cvPixelBuffer];
                CIContext *temporaryContext = [CIContext contextWithOptions:nil];
                CGImageRef cgImage = [temporaryContext createCGImage:ciImage fromRect:ciImage.extent];
                
                CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                
                if (!cgImage) {
                    return nil;
                }
                
                UIImage *image = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                
                return image;
            }
        }
        
        return nil;
    } @catch (NSException *e) {
        writeLog(@"[WebRTCFrameConverter] Exceção ao converter frame para UIImage: %@", e);
        return nil;
    }
}

- (CMSampleBufferRef)getLatestSampleBuffer {
    // Para uso futuro na substituição do feed da câmera
    return NULL;
}

@end
