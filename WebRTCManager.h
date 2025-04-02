#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

/**
 * WebRTCManager
 *
 * Classe responsável por gerenciar conexões WebRTC.
 * Versão simplificada otimizada para VCamWebRTC.
 */
@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>

/**
 * Obtém a instância compartilhada (singleton).
 */
+ (instancetype)sharedInstance;

/**
 * Inicia a conexão WebRTC com o servidor.
 * @param serverIP Endereço IP do servidor WebRTC
 */
- (void)startWebRTCWithServer:(NSString *)serverIP;

/**
 * Inicia a conexão WebRTC com o servidor usando o serverIP já configurado.
 */
- (void)startWebRTC;

/**
 * Encerra a conexão WebRTC.
 */
- (void)stopWebRTC;

/**
 * Obtém o último frame como CMSampleBuffer para substituição da câmera.
 * @return CMSampleBufferRef formatado para compatibilidade com câmera nativa
 */
- (CMSampleBufferRef)getLatestVideoSampleBuffer;

/**
 * Versão aprimorada que permite aplicar metadados da câmera original
 * ao buffer criado pelo WebRTC para uma substituição perfeita
 *
 * @param originalBuffer Buffer original da câmera (opcional)
 * @return Buffer WebRTC com timing e metadados sincronizados
 */
- (CMSampleBufferRef)getLatestVideoSampleBufferWithOriginalMetadata:(CMSampleBufferRef)originalBuffer;

/**
 * Adapta-se à câmera nativa com a posição especificada.
 * @param position Posição da câmera (frontal/traseira).
 */
- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position;

/**
 * Define a resolução alvo para adaptação.
 * @param resolution Dimensões da resolução desejada.
 */
- (void)setTargetResolution:(CMVideoDimensions)resolution;

/**
 * Adapta a saída de vídeo para a orientação especificada.
 * @param orientation Orientação de vídeo a ser aplicada (valores de AVCaptureVideoOrientation).
 */
- (void)adaptOutputToVideoOrientation:(int)orientation;

/**
 * Define se o vídeo deve ser espelhado.
 * @param mirrored TRUE se o vídeo deve ser espelhado, FALSE caso contrário.
 */
- (void)setVideoMirrored:(BOOL)mirrored;

/**
 * Endereço IP do servidor WebRTC.
 */
@property (nonatomic, strong) NSString *serverIP;

/**
 * Verifica se a conexão WebRTC está estabelecida.
 */
@property (nonatomic, readonly, getter=isConnected) BOOL connected;

/**
 * Informa se o WebRTC está recebendo frames.
 */
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

/**
 * Estado atual da conexão.
 */
@property (nonatomic, assign, readonly) int connectionState;

/**
 * Callback para atualização de status.
 */
@property (nonatomic, copy) void (^statusUpdateCallback)(NSString *status);

@end

#endif /* WEBRTCMANAGER_H */
