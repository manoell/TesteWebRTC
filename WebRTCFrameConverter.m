#import "WebRTCFrameConverter.h"
#import "logger.h"

@implementation WebRTCFrameConverter {
    RTCCVPixelBuffer *_pixelBuffer;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _processingQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing", DISPATCH_QUEUE_SERIAL);
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

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
    writeLog(@"[WebRTCFrameConverter] setSize chamado: %@", NSStringFromCGSize(size));
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    static int frameCount = 0;
    
    frameCount++;
    if (frameCount % 10 == 0) {  // Log a cada 10 frames para não sobrecarregar
        writeLog(@"[WebRTCFrameConverter] renderFrame chamado %d vezes", frameCount);
    }
    
    [self setRenderFrame:frame];
}

- (void)setRenderFrame:(RTCVideoFrame *)frame {
    if (!self.frameCallback) {
        writeLog(@"[WebRTCFrameConverter] frameCallback não configurado");
        return;
    }
    
    dispatch_async(_processingQueue, ^{
        UIImage *image = [self imageFromVideoFrame:frame];
        if (image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.frameCallback(image);
            });
        } else {
            writeLog(@"[WebRTCFrameConverter] Falha ao converter frame para UIImage");
        }
    });
}

- (UIImage *)imageFromVideoFrame:(RTCVideoFrame *)frame {
    @try {
        if (!frame) {
            writeLog(@"[WebRTCFrameConverter] Frame nulo recebido");
            return nil;
        }
        
        RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
        if (![pixelBuffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            writeLog(@"[WebRTCFrameConverter] Tipo de buffer não suportado: %@", [frame.buffer class]);
            return nil;
        }
        
        CVPixelBufferRef cvPixelBuffer = pixelBuffer.pixelBuffer;
        if (!cvPixelBuffer) {
            writeLog(@"[WebRTCFrameConverter] CVPixelBuffer nulo");
            return nil;
        }
        
        // Bloquear o buffer para acesso
        CVPixelBufferLockBaseAddress(cvPixelBuffer, 0);
        
        // Obter informações do buffer
        size_t width = CVPixelBufferGetWidth(cvPixelBuffer);
        size_t height = CVPixelBufferGetHeight(cvPixelBuffer);
        
        // Criar contexto gráfico
        CGContextRef context = CGBitmapContextCreate(
            CVPixelBufferGetBaseAddress(cvPixelBuffer),
            width,
            height,
            8,
            CVPixelBufferGetBytesPerRow(cvPixelBuffer),
            _colorSpace,
            kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast
        );
        
        // Verificar se o contexto foi criado com sucesso
        if (!context) {
            writeLog(@"[WebRTCFrameConverter] Falha ao criar contexto gráfico");
            CVPixelBufferUnlockBaseAddress(cvPixelBuffer, 0);
            return nil;
        }
        
        // Criar imagem
        CGImageRef cgImage = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        
        // Desbloquear o buffer
        CVPixelBufferUnlockBaseAddress(cvPixelBuffer, 0);
        
        if (!cgImage) {
            writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage");
            return nil;
        }
        
        // Criar UIImage
        UIImage *image = [UIImage imageWithCGImage:cgImage];
        CGImageRelease(cgImage);
        
        return image;
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
