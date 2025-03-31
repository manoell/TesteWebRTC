#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WebRTCManager.h"
#import "WebRTCFrameConverter.h"

/**
 * WebRTCCameraAdapter
 *
 * Classe responsável por adaptar frames do WebRTC para uso com a câmera nativa do iOS.
 * Gerencia conversão de formatos, sincronização de timestamps e metadados.
 */
@interface WebRTCCameraAdapter : NSObject

/**
 * Instância compartilhada (singleton)
 */
+ (instancetype)sharedInstance;

/**
 * WebRTCManager usado para obter frames
 */
@property (nonatomic, strong) WebRTCManager *webRTCManager;

/**
 * Indica se a substituição está ativa
 */
@property (nonatomic, assign, getter=isActive) BOOL active;

/**
 * Inicia o adaptador com um WebRTCManager específico
 * @param manager O WebRTCManager que fornecerá os frames
 */
- (void)startWithManager:(WebRTCManager *)manager;

/**
 * Para o adaptador e libera recursos
 */
- (void)stop;

/**
 * Obtém um frame adaptado para substituir um frame original da câmera
 * @param originalBuffer O buffer original da câmera (para referência de formato e timing)
 * @return Um novo buffer adaptado do WebRTC, ou nil se não disponível
 */
- (CMSampleBufferRef)getAdaptedFrameForOriginal:(CMSampleBufferRef)originalBuffer;

/**
 * Atualiza o buffer da camada de preview com o frame WebRTC atual
 * @param previewLayer A camada de preview para atualizar
 * @return TRUE se a atualização foi bem-sucedida
 */
- (BOOL)updatePreviewLayer:(AVSampleBufferDisplayLayer *)previewLayer;

/**
 * Detecta e adapta para o formato da câmera atual
 * @param format Formato OSType da câmera (como kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
 * @param dimensions Dimensões da câmera
 */
- (void)adaptToCameraFormat:(OSType)format dimensions:(CMVideoDimensions)dimensions;

/**
 * Define a orientação do vídeo
 * @param orientation A orientação (como AVCaptureVideoOrientationPortrait)
 */
- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation;

/**
 * Define o status de espelhamento (para câmera frontal)
 * @param mirrored TRUE se a imagem deve ser espelhada
 */
- (void)setVideoMirrored:(BOOL)mirrored;

/**
 * Obtém informações sobre estado atual
 * @return Dicionário com informações de estado
 */
- (NSDictionary *)getStatus;

@end
