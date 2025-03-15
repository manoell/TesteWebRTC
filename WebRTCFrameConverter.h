#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

/**
 * WebRTCFrameConverter
 *
 * Classe responsável por converter frames WebRTC em formatos utilizáveis por UIKit (UIImage)
 * e AVFoundation (CMSampleBuffer). Otimizada para alta resolução (1080p+).
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
 * @return CMSampleBufferRef contendo o frame atual, ou NULL se não disponível.
 */
- (CMSampleBufferRef)getLatestSampleBuffer;

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
 * Reset o conversor para um estado limpo.
 * Limpa o cache interno e reinicia contadores.
 */
- (void)reset;

@end
