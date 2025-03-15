#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;
@class WebRTCFrameConverter;

/**
 * Estado de conexão do WebRTCManager
 */
typedef NS_ENUM(NSInteger, WebRTCManagerState) {
    WebRTCManagerStateDisconnected,    // Desconectado do servidor WebRTC
    WebRTCManagerStateConnecting,      // Tentando conectar ao servidor WebRTC
    WebRTCManagerStateConnected,       // Conectado e pronto para receber frames
    WebRTCManagerStateError,           // Erro na conexão WebRTC
    WebRTCManagerStateReconnecting     // Reconectando após falha
};

/**
 * WebRTCManager
 *
 * Classe responsável pelo gerenciamento da conexão WebRTC.
 * Controla a sinalização, negociação e recepção do stream de vídeo em alta qualidade.
 * Inclui capacidade de auto-adaptação para diferentes câmeras.
 */
@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>

/**
 * Estado atual da conexão WebRTC
 */
@property (nonatomic, assign, readonly) WebRTCManagerState state;

/**
 * Conexão WebRTC
 */
@property (nonatomic, strong) RTCPeerConnection *peerConnection;

/**
 * Factory para criação de objetos WebRTC
 */
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;

/**
 * Referência à janela flutuante para atualização de UI
 */
@property (nonatomic, weak) FloatingWindow *floatingWindow;

/**
 * Track de vídeo recebido
 */
@property (nonatomic, strong) RTCVideoTrack *videoTrack;

/**
 * Conversor de frames para processamento do vídeo recebido
 */
@property (nonatomic, strong) WebRTCFrameConverter *frameConverter;

/**
 * Flag indicando se a desconexão foi solicitada pelo usuário
 */
@property (nonatomic, assign) BOOL userRequestedDisconnect;

/**
 * Flag indicando se está recebendo frames
 */
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

/**
 * Endereço IP do servidor
 */
@property (nonatomic, strong) NSString *serverIP;

/**
 * Inicializa o gerenciador com referência à janela flutuante.
 * @param window FloatingWindow para atualização de interface.
 * @return Nova instância do gerenciador.
 */
- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;

/**
 * Inicia a conexão WebRTC.
 * Configura WebRTC, conecta ao servidor de sinalização e inicia a negociação.
 */
- (void)startWebRTC;

/**
 * Encerra a conexão WebRTC.
 * Libera todos os recursos e fecha conexões.
 * @param userInitiated Indica se a desconexão foi solicitada pelo usuário
 */
- (void)stopWebRTC:(BOOL)userInitiated;

/**
 * Gera e envia uma imagem de teste para visualização durante a conexão.
 * Útil para indicar que a aplicação está funcionando enquanto aguarda conexão.
 */
- (void)captureAndSendTestImage;

/**
 * Obtém o buffer de amostra mais recente para injeção na câmera.
 * @return CMSampleBufferRef contendo o frame atual, ou NULL se não disponível.
 */
- (CMSampleBufferRef)getLatestVideoSampleBuffer;

/**
 * Verifica o status atual da conexão WebRTC e seus componentes.
 * Gera logs detalhados sobre o estado.
 */
- (void)checkWebRTCStatus;

/**
 * Coleta estatísticas de qualidade da conexão WebRTC.
 * Analisa resolução, framerate, perda de pacotes, etc.
 */
- (void)gatherConnectionStats;

/**
 * Define manualmente a resolução alvo para adaptação.
 * @param resolution Resolução desejada (largura x altura).
 */
- (void)setTargetResolution:(CMVideoDimensions)resolution;

/**
 * Define manualmente a taxa de quadros alvo.
 * @param frameRate Taxa de quadros desejada (fps).
 */
- (void)setTargetFrameRate:(float)frameRate;

/**
 * Define IP do servidor WebRTC.
 * @param ip Endereço IP do servidor
 */
- (void)setServerIP:(NSString *)ip;

/**
 * Detecta e se adapta à resolução da câmera atual do dispositivo iOS.
 * A adaptação pode ser feita para câmera frontal ou traseira.
 * @param position Posição da câmera (frontal ou traseira).
 */
- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position;

/**
 * Ativa ou desativa a auto-adaptação para a câmera nativa.
 * Quando ativada, o sistema irá automaticamente adaptar a resolução e taxa de quadros
 * para corresponder à câmera atualmente selecionada no sistema.
 * @param enable Estado da auto-adaptação.
 */
- (void)setAutoAdaptToCameraEnabled:(BOOL)enable;

/**
 * Mute/unmute áudio
 */
- (void)muteAudioIn;
- (void)unmuteAudioIn;

/**
 * Mute/unmute vídeo
 */
- (void)muteVideoIn;
- (void)unmuteVideoIn;

/**
 * Controle de alto-falante
 */
- (void)enableSpeaker;
- (void)disableSpeaker;

/**
 * Controle de câmeras
 */
- (void)swapCameraToFront;
- (void)swapCameraToBack;

/**
 * Coleta estatísticas de qualidade da conexão WebRTC.
 * @return Dicionário contendo estatísticas como RTT, perdas de pacotes, etc.
 */
- (NSDictionary *)getConnectionStats;

@end

#endif /* WEBRTCMANAGER_H */
