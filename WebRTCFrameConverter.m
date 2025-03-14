#import "WebRTCFrameConverter.h"
#import "logger.h"

@implementation WebRTCFrameConverter {
    RTCCVPixelBuffer *_pixelBuffer;
    CGColorSpaceRef _colorSpace;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _colorSpace = CGColorSpaceCreateDeviceRGB();
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
    // Não precisamos fazer nada aqui
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    static int frameCount = 0;
    
    frameCount++;
    if (frameCount % 30 == 0) {  // Log a cada 30 frames para não sobrecarregar
        writeLog(@"[Converter] renderFrame chamado %d vezes", frameCount);
    }
    
    [self setRenderFrame:frame];
}

- (void)setRenderFrame:(RTCVideoFrame *)frame {
    if (!self.frameCallback) return;
    
    @autoreleasepool {
        UIImage *image = [self imageFromVideoFrame:frame];
        if (image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.frameCallback(image);
            });
        }
    }
}

- (UIImage *)imageFromVideoFrame:(RTCVideoFrame *)frame {
    @try {
        if (!frame) {
            writeLog(@"[Converter] Frame nulo recebido");
            return nil;
        }
        
        writeLog(@"[Converter] Tipo de buffer: %@", [frame.buffer class]);
        
        RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
        if (![pixelBuffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            writeLog(@"[Converter] Tipo de buffer não suportado: %@", [frame.buffer class]);
            return nil;
        }
        
        CVPixelBufferRef cvPixelBuffer = pixelBuffer.pixelBuffer;
        if (!cvPixelBuffer) {
            writeLog(@"[Converter] CVPixelBuffer nulo");
            return nil;
        }
        
        writeLog(@"[Converter] CVPixelBuffer obtido, formato: %d", (int)CVPixelBufferGetPixelFormatType(cvPixelBuffer));
        
        // Tentar criar CIImage
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:cvPixelBuffer];
        if (!ciImage) {
            writeLog(@"[Converter] Falha ao criar CIImage");
            return nil;
        }
        
        writeLog(@"[Converter] CIImage criado com sucesso, tamanho: %@", NSStringFromCGRect(ciImage.extent));
        
        // Tentar criar CGImage
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
        if (!cgImage) {
            writeLog(@"[Converter] Falha ao criar CGImage");
            return nil;
        }
        
        writeLog(@"[Converter] CGImage criado com sucesso");
        
        // Criar UIImage
        UIImage *image = [UIImage imageWithCGImage:cgImage];
        CGImageRelease(cgImage);
        
        if (image) {
            writeLog(@"[Converter] UIImage criado com sucesso: %@", NSStringFromCGSize(image.size));
        } else {
            writeLog(@"[Converter] Falha ao criar UIImage");
        }
        
        return image;
    } @catch (NSException *e) {
        writeLog(@"[Converter] Exceção ao converter frame para UIImage: %@", e);
        return nil;
    }
}

@end
