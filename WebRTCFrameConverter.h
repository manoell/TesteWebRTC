#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

/**
 * Enum para formatos de pixel nativos do iOS
 */
typedef NS_ENUM(NSInteger, IOSPixelFormat) {
    IOSPixelFormatUnknown = 0,
    IOSPixelFormat420f,   // YUV 4:2:0 full-range (formato preferido do iOS)
    IOSPixelFormat420v,   // YUV 4:2:0 video-range
    IOSPixelFormatBGRA    // 32-bit BGRA
};

/**
 * WebRTCFrameConverter
 *
 * Classe responsável por converter frames WebRTC em formatos utilizáveis por UIKit (UIImage)
 * e AVFoundation (CMSampleBuffer). Otimizada para alta resolução (1080p+) e formatos nativos iOS.
 */
@interface WebRTCFrameConverter : NSObject <RTCVideoRenderer>

/**
 * Callback chamado quando um novo frame está disponível.
 * @param image UIImage convertida do frame WebRTC.
 */
@property (nonatomic, copy) void (^frameCallback)(UIImage *image);

/**
 * Indica se o converter está recebendo frames ativamente.
 */
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

/**
 * Contador de frames recebidos.
 */
@property (nonatomic, assign, readonly) int frameCount;

/**
 * Formato atual de pixel detectado dos frames recebidos
 */
@property (nonatomic, assign, readonly) IOSPixelFormat detectedPixelFormat;

/**
 * Forma como os frames estão sendo processados (hardware/software)
 */
@property (nonatomic, copy, readonly) NSString *processingMode;

@property (nonatomic, assign, readonly) NSUInteger totalSampleBuffersCreated;
@property (nonatomic, assign, readonly) NSUInteger totalSampleBuffersReleased;
@property (nonatomic, assign) NSUInteger totalPixelBuffersLocked;
@property (nonatomic, assign) NSUInteger totalPixelBuffersUnlocked;

/**
 * Dicionário para rastreamento ativo de sample buffers
 */
@property (nonatomic, strong, readonly) NSMutableDictionary *activeSampleBuffers;

/**
 * Dicionário para timestamps de cache
 */
@property (nonatomic, strong, readonly) NSMutableDictionary *sampleBufferCacheTimestamps;

/**
 * Timer para monitoramento de recursos
 */
@property (nonatomic, strong) dispatch_source_t resourceMonitorTimer;

/**
 * Inicializa o conversor de frames.
 * @return Uma nova instância do conversor.
 */
- (instancetype)init;

/**
 * Define manualmente um frame para renderização.
 * @param frame O frame WebRTC a ser renderizado.
 */
- (void)setRenderFrame:(RTCVideoFrame *)frame;

/**
 * Obtém o buffer de amostra mais recente, adequado para injeção em AVCaptureSession.
 * @param pixelFormat Formato de pixel desejado para o buffer de saída
 * @return CMSampleBufferRef contendo o frame atual, ou NULL se não disponível.
 */
- (CMSampleBufferRef)getLatestSampleBufferWithFormat:(IOSPixelFormat)pixelFormat;

/**
 * Obtém o buffer de amostra mais recente usando o formato nativo detectado.
 * @return CMSampleBufferRef contendo o frame atual, ou NULL se não disponível.
 */
- (CMSampleBufferRef)getLatestSampleBuffer;

/**
 * Cria um CMSampleBuffer a partir do último frame com formatação específica.
 * @param format Formato de pixel desejado (kCVPixelFormatType_*)
 * @return CMSampleBufferRef formatado, ou NULL em caso de erro
 */
- (CMSampleBufferRef)createSampleBufferWithFormat:(OSType)format;

/**
 * Obtém o último frame como UIImage.
 * @return UIImage do último frame recebido, ou nil se não disponível.
 */
- (UIImage *)getLastFrameAsImage;

/**
 * Obtém estatísticas de processamento de frame.
 * @return NSDictionary contendo estatísticas como tempo médio de processamento e FPS.
 */
- (NSDictionary *)getFrameProcessingStats;

/**
 * Define a resolução alvo para adaptação.
 * @param resolution A resolução de destino para adaptar os frames.
 */
- (void)setTargetResolution:(CMVideoDimensions)resolution;

/**
 * Define a taxa de quadros alvo para adaptação.
 * @param frameRate Taxa de quadros desejada em fps.
 */
- (void)setTargetFrameRate:(float)frameRate;

/**
 * Adapta-se ao formato específico da câmera atual do iOS.
 * @param format Formato de pixel nativo (como kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
 * @param resolution Resolução da câmera
 */
- (void)adaptToNativeCameraFormat:(OSType)format resolution:(CMVideoDimensions)resolution;

/**
 * Converte um formato OSType de CoreVideo para formato IOSPixelFormat.
 * @param cvFormat Formato OSType de CoreVideo (como kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
 * @return IOSPixelFormat correspondente
 */
+ (IOSPixelFormat)pixelFormatFromCVFormat:(OSType)cvFormat;

/**
 * Converte um IOSPixelFormat para OSType de CoreVideo.
 * @param iosFormat Formato IOSPixelFormat
 * @return OSType de CoreVideo correspondente
 */
+ (OSType)cvFormatFromPixelFormat:(IOSPixelFormat)iosFormat;

/**
 * Retorna uma string descritiva para o formato de pixel.
 * @param format Formato IOSPixelFormat
 * @return String descritiva do formato
 */
+ (NSString *)stringFromPixelFormat:(IOSPixelFormat)format;

/**
 * Reset o conversor para um estado limpo.
 * Limpa o cache interno e reinicia contadores.
 */
- (void)reset;

/**
 * Realiza uma limpeza segura de todos os recursos.
 * Este método deve ser chamado quando o app entra em background ou em situações de baixa memória.
 */
- (void)performSafeCleanup;

/**
 * Libera explicitamente um CMSampleBuffer e atualiza contadores.
 * @param buffer O buffer a ser liberado.
 */
- (void)releaseSampleBuffer:(CMSampleBufferRef)buffer;

/**
 * Monitora e corrige automaticamente vazamentos de recursos.
 */
- (void)checkForResourceLeaks;

/**
 * Inicia o monitoramento periódico de recursos.
 */
- (void)startResourceMonitoring;

/**
 * Otimiza o sistema de cache removendo entradas antigas.
 */
- (void)optimizeCacheSystem;

@end
