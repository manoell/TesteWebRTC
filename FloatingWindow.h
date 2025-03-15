#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@class WebRTCManager;

/**
 * Estados possíveis da FloatingWindow
 */
typedef NS_ENUM(NSInteger, FloatingWindowState) {
    FloatingWindowStateNormal,     // Tamanho normal
    FloatingWindowStateMinimized,  // Versão minimizada
    FloatingWindowStateExpanded,   // Versão expandida com controles
    FloatingWindowStateFullscreen  // Versão em tela cheia
};

/**
 * FloatingWindow
 *
 * Janela flutuante que exibe o preview do stream WebRTC.
 */
@interface FloatingWindow : UIWindow <RTCVideoViewDelegate>

/**
 * View para renderização direta do vídeo WebRTC
 */
@property (nonatomic, strong, readonly) RTCMTLVideoView *videoView;

/**
 * Gerenciador WebRTC para controle da conexão
 */
@property (nonatomic, strong) WebRTCManager *webRTCManager;

/**
 * Estado atual da janela
 */
@property (nonatomic, assign) FloatingWindowState windowState;

/**
 * Mostra se está recebendo frames
 */
@property (nonatomic, assign) BOOL isReceivingFrames;

/**
 * Frame rate atual
 */
@property (nonatomic, assign) float currentFps;

/**
 * Tamanho do último frame recebido
 */
@property (nonatomic, assign) CGSize lastFrameSize;

/**
 * Mostra se o bloco de transparência está ativo
 */
@property (nonatomic, assign) BOOL isTranslucent;

/**
 * Botão para ativar/desativar o preview
 */
@property (nonatomic, strong) UIButton *toggleButton;

/**
 * Label para exibição do status da conexão
 */
@property (nonatomic, strong) UILabel *statusLabel;

#pragma mark - Initialization & Lifecycle Methods

/**
 * Inicializa a janela flutuante com um quadro específico.
 */
- (instancetype)initWithFrame:(CGRect)frame;

/**
 * Exibe a janela flutuante.
 */
- (void)show;

/**
 * Oculta a janela flutuante e para o preview.
 */
- (void)hide;

/**
 * Alterna entre iniciar e parar o preview.
 */
- (void)togglePreview:(UIButton *)sender;

/**
 * Atualiza o status da conexão exibido.
 */
- (void)updateConnectionStatus:(NSString *)status;

@end
