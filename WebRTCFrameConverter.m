#import "WebRTCFrameConverter.h"
#import "logger.h"

@implementation WebRTCFrameConverter {
    RTCVideoFrame *_lastFrame;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _processingQueue;
    BOOL _isReceivingFrames;
    int _frameCount;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing", DISPATCH_QUEUE_SERIAL);
        _isReceivingFrames = NO;
        _frameCount = 0;
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
    _frameCount++;
    _isReceivingFrames = YES;
    
    if (_frameCount == 1 || _frameCount % 30 == 0) {
        writeLog(@"[WebRTCFrameConverter] renderFrame #%d recebido: %dx%d",
                _frameCount,
                (int)frame.width,
                (int)frame.height);
        
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        writeLog(@"[WebRTCFrameConverter] Tipo do buffer: %@", NSStringFromClass([buffer class]));
    }
    
    _lastFrame = frame;
    
    if (!self.frameCallback) {
        if (_frameCount == 1 || _frameCount % 100 == 0) {
            writeLog(@"[WebRTCFrameConverter] AVISO: frameCallback não configurado");
        }
        return;
    }
    
    dispatch_async(_processingQueue, ^{
        UIImage *image = [self imageFromVideoFrame:frame];
        if (image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.frameCallback(image);
            });
        } else {
            if (self->_frameCount == 1 || self->_frameCount % 30 == 0) {
                writeLog(@"[WebRTCFrameConverter] Falha ao converter frame para UIImage");
            }
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
            
            // Bloquear o buffer para acesso
            CVPixelBufferLockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
            
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:cvPixelBuffer];
            CIContext *temporaryContext = [CIContext contextWithOptions:nil];
            CGImageRef cgImage = [temporaryContext createCGImage:ciImage fromRect:ciImage.extent];
            
            CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
            
            if (!cgImage) {
                return nil;
            }
            
            UIImage *image = [UIImage imageWithCGImage:cgImage];
            CGImageRelease(cgImage);
            
            if (_frameCount == 1) {
                writeLog(@"[WebRTCFrameConverter] Primeira imagem convertida com sucesso: %dx%d",
                        (int)image.size.width,
                        (int)image.size.height);
            }
            
            return image;
        }
        // Método para I420Buffer
        else if (NSClassFromString(@"RTCI420Buffer") && [buffer isKindOfClass:NSClassFromString(@"RTCI420Buffer")]) {
            writeLog(@"[WebRTCFrameConverter] Buffer I420 detectado, não implementado ainda");
            return nil;
        }
        
        if (_frameCount == 1 || _frameCount % 30 == 0) {
            writeLog(@"[WebRTCFrameConverter] Tipo de buffer não suportado: %@", NSStringFromClass([buffer class]));
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
