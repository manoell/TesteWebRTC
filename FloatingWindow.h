#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@class WebRTCManager;

/**
 * FloatingWindow
 *
 * Janela flutuante que exibe o preview do stream WebRTC e permite controlar a conexão.
 * Inclui funcionalidades para manipulação e visualização do vídeo em alta resolução.
 */
@interface FloatingWindow : UIWindow

/**
 * View para exibição do preview da imagem recebida
 */
@property (nonatomic, strong) UIImageView *previewImageView;

/**
 * Gerenciador WebRTC para controle da conexão
 */
@property (nonatomic, strong) WebRTCManager *webRTCManager;

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

/**
 * Gesture recognizer para mover a janela
 */
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;

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
 * Atualiza a imagem de preview.
 * @param image Nova imagem para exibir no preview.
 */
- (void)updatePreviewImage:(UIImage *)image;

/**
 * Atualiza o status da conexão exibido.
 * Também adapta a cor do indicador conforme o status.
 * @param status String de status a ser exibida.
 */
- (void)updateConnectionStatus:(NSString *)status;

/**
 * Inicia o monitoramento do recebimento de frames.
 * Verifica se frames estão sendo recebidos e atualiza o status apropriadamente.
 */
- (void)startFrameMonitoring;

/**
 * Adiciona gesture de duplo toque para minimizar/maximizar a janela.
 */
- (void)addDoubleTapGesture;

/**
 * Configura a janela para substituição do feed da câmera.
 * Prepara a integração com o sistema de câmera do iOS.
 */
- (void)setupForCameraReplacement;

@end
