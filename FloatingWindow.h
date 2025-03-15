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
 * Janela flutuante simplificada que exibe o preview do stream WebRTC.
 * Utiliza RTCMTLVideoView para renderização direta e eficiente do vídeo.
 */
@interface FloatingWindow : UIWindow <RTCVideoViewDelegate>

#pragma mark - Properties

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
 * Mostra se o bloco de transparência está ativo
 */
@property (nonatomic, assign) BOOL isTranslucent;

#pragma mark - UI Components

/**
 * Botão para ativar/desativar o preview
 */
@property (nonatomic, strong) UIButton *toggleButton;

/**
 * Label para exibição do status da conexão
 */
@property (nonatomic, strong) UILabel *statusLabel;

/**
 * View container para componentes da UI
 */
@property (nonatomic, strong) UIView *contentView;

#pragma mark - Gesture Recognizers

/**
 * Gesture recognizer para mover a janela
 */
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;

/**
 * Gesture de duplo toque para minimizar/maximizar
 */
@property (nonatomic, strong) UITapGestureRecognizer *doubleTapGesture;

#pragma mark - Initialization & Lifecycle Methods

/**
 * Inicializa a janela flutuante com um quadro específico.
 * @param frame Retângulo definindo a posição e tamanho da janela.
 * @return Nova instância da janela flutuante.
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

#pragma mark - Preview Control Methods

/**
 * Alterna entre iniciar e parar o preview.
 * @param sender Botão que acionou a ação.
 */
- (void)togglePreview:(UIButton *)sender;

/**
 * Inicia o preview WebRTC.
 * Conecta ao servidor e começa a receber o stream.
 */
- (void)startPreview;

/**
 * Para o preview WebRTC.
 * Desconecta do servidor e limpa a imagem.
 */
- (void)stopPreview;

/**
 * Atualiza o status da conexão exibido.
 * @param status String de status a ser exibida.
 */
- (void)updateConnectionStatus:(NSString *)status;

#pragma mark - Window Management Methods

/**
 * Alterna entre diferentes estados da janela (normal, minimizado, expandido, etc.)
 * @param newState Novo estado da janela.
 * @param animated Se a transição deve ser animada.
 */
- (void)changeWindowState:(FloatingWindowState)newState animated:(BOOL)animated;

/**
 * Minimiza a janela para um estado compacto.
 * @param animated Se a transição deve ser animada.
 */
- (void)minimizeWindow:(BOOL)animated;

/**
 * Expande a janela para um tamanho normal/médio.
 * @param animated Se a transição deve ser animada.
 */
- (void)expandWindow:(BOOL)animated;

@end
