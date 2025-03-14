#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;
@class WebRTCFrameConverter;

/**
 * WebRTCManager
 *
 * Classe responsável pelo gerenciamento da conexão WebRTC.
 * Controla a sinalização, negociação e recepção do stream de vídeo em alta qualidade.
 * Inclui capacidade de auto-adaptação para diferentes câmeras.
 */
@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>

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
 * Timer usado para enviar imagens de teste durante conexão
 */
@property (nonatomic, strong) NSTimer *frameTimer;

/**
 * Conversor de frames para processamento do vídeo recebido
 */
@property (nonatomic, strong) WebRTCFrameConverter *frameConverter;

/**
 * Estado da conexão
 */
@property (nonatomic, assign) BOOL isConnected;

/**
 * Tarefa WebSocket para comunicação de sinalização
 */
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;

/**
 * Sessão URL para WebSocket
 */
@property (nonatomic, strong) NSURLSession *session;

/**
 * Modo de auto-adaptação para resolução da câmera
 */
@property (nonatomic, assign) BOOL autoAdaptToCameraResolution;

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
 */
- (void)stopWebRTC;

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
 * Converte estado da conexão ICE para string legível.
 * @param state Estado da conexão ICE.
 * @return String descritiva do estado.
 */
- (NSString *)iceConnectionStateToString:(RTCIceConnectionState)state;

/**
 * Converte estado de sinalização para string legível.
 * @param state Estado da sinalização WebRTC.
 * @return String descritiva do estado.
 */
- (NSString *)signalingStateToString:(RTCSignalingState)state;

/**
 * Conecta ao servidor WebSocket para sinalização.
 */
- (void)connectWebSocket;

/**
 * Configura recebimento de mensagens WebSocket.
 */
- (void)receiveMessage;

/**
 * Processa uma oferta SDP recebida.
 * @param sdp String SDP da oferta.
 */
- (void)handleOfferWithSDP:(NSString *)sdp;

/**
 * Otimiza uma SDP para suportar vídeo de alta qualidade.
 * @param originalSdp SDP original.
 * @return SDP modificada otimizada.
 */
- (NSString *)enhanceSdpForHighQuality:(NSString *)originalSdp;

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
 * Define manualmente a resolução alvo para adaptação.
 * @param resolution Resolução desejada (largura x altura).
 */
- (void)setTargetResolution:(CMVideoDimensions)resolution;

/**
 * Define manualmente a taxa de quadros alvo.
 * @param frameRate Taxa de quadros desejada (fps).
 */
- (void)setTargetFrameRate:(float)frameRate;

@end
