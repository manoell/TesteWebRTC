#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"
#import <WebRTC/WebRTC.h>

@interface FloatingWindow ()
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, assign) NSTimeInterval lastImageUpdate;
@property (nonatomic, strong) UIPanGestureRecognizer *contentPanGesture;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *minimizeButton;
@property (nonatomic, strong) UIButton *infoButton;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic, assign) CGRect originalFrame;
@property (nonatomic, strong) UILabel *connectionInfoLabel;
@property (nonatomic, strong) UIStackView *controlsStackView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic, assign) BOOL controlsVisible;
@property (nonatomic, assign) CGSize lastFrameSize;
@property (nonatomic, assign) BOOL dragInProgress;

// RTCVideoView para renderização direta de frames WebRTC
@property (nonatomic, strong, readwrite) RTCMTLVideoView *videoView;
@end

@implementation FloatingWindow

#pragma mark - Initialization & Setup

- (instancetype)initWithFrame:(CGRect)frame {
    if (@available(iOS 13.0, *)) {
        UIScene *scene = [[UIApplication sharedApplication].connectedScenes anyObject];
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self = [super initWithWindowScene:(UIWindowScene *)scene];
        } else {
            self = [super initWithFrame:frame];
        }
    } else {
        self = [super initWithFrame:frame];
    }
    
    if (self) {
        self.frame = frame;
        self.originalFrame = frame;
        self.windowState = FloatingWindowStateNormal;
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.7].CGColor;
        
        // Melhorar a sombra para aparência mais moderna
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        
        [self setupUI];
        
        // Inicializar WebRTC manager
        self.webRTCManager = [[WebRTCManager alloc] initWithFloatingWindow:self];
        
        self.isPreviewActive = NO;
        self.lastImageUpdate = 0;
        self.controlsVisible = YES;
        self.lastFrameSize = CGSizeZero;
        self.isTranslucent = YES;
        
        // Iniciar temporizador para auto-ocultar controles
        [self resetAutoHideTimer];
        
        writeLog(@"[FloatingWindow] Janela flutuante inicializada com UI simplificada");
    }
    return self;
}

- (void)setupUI {
    // Container principal com layout constraints
    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = [UIColor clearColor];
    [self addSubview:self.contentView];
    
    // Layout para contentView preencher a janela
    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    
    // Configurar RTCMTLVideoView para renderização direta
    [self setupVideoView];
    
    // Configurar barra superior com status
    [self setupStatusBar];
    
    // Configurar botões de controle
    [self setupControlButtons];
    
    // Configurar indicador de carregamento
    [self setupLoadingIndicator];
    
    // Configurar gestos
    [self setupGestureRecognizers];
    
    // Configurar fundo gradiente para barras de controle
    [self setupGradients];
}

- (void)setupVideoView {
    // Usar RTCMTLVideoView para renderização eficiente de vídeo
    self.videoView = [[RTCMTLVideoView alloc] init];
    if (!self.videoView) {
        writeErrorLog(@"[FloatingWindow] Falha ao criar RTCMTLVideoView");
        return;
    }
    
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.delegate = self;
    self.videoView.backgroundColor = [UIColor blackColor];
    [self.contentView addSubview:self.videoView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.videoView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.videoView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
    
    writeLog(@"[FloatingWindow] VideoView configurada com sucesso");
}

- (void)setupStatusBar {
    // Barra de status superior com gradiente
    UIView *statusBarView = [[UIView alloc] init];
    statusBarView.translatesAutoresizingMaskIntoConstraints = NO;
    statusBarView.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:statusBarView];
    
    [NSLayoutConstraint activateConstraints:@[
        [statusBarView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [statusBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [statusBarView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [statusBarView.heightAnchor constraintEqualToConstant:44],
    ]];
    
    // Status Label com design aprimorado
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"WebRTC Preview";
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.layer.cornerRadius = 8;
    self.statusLabel.clipsToBounds = YES;
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    [statusBarView addSubview:self.statusLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:statusBarView.centerXAnchor],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:statusBarView.widthAnchor constant:-80],
        [self.statusLabel.heightAnchor constraintEqualToConstant:30],
    ]];
    
    // Botões de controle da barra superior
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        [self.closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    } else {
        [self.closeButton setTitle:@"X" forState:UIControlStateNormal];
    }
    [self.closeButton addTarget:self action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.closeButton.tintColor = [UIColor whiteColor];
    [statusBarView addSubview:self.closeButton];
    
    self.minimizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.minimizeButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        [self.minimizeButton setImage:[UIImage systemImageNamed:@"minus.circle.fill"] forState:UIControlStateNormal];
    } else {
        [self.minimizeButton setTitle:@"-" forState:UIControlStateNormal];
    }
    [self.minimizeButton addTarget:self action:@selector(minimizeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.minimizeButton.tintColor = [UIColor whiteColor];
    [statusBarView addSubview:self.minimizeButton];
    
    self.infoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.infoButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        [self.infoButton setImage:[UIImage systemImageNamed:@"info.circle.fill"] forState:UIControlStateNormal];
    } else {
        [self.infoButton setTitle:@"i" forState:UIControlStateNormal];
    }
    [self.infoButton addTarget:self action:@selector(infoButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.infoButton.tintColor = [UIColor whiteColor];
    [statusBarView addSubview:self.infoButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.closeButton.leadingAnchor constraintEqualToAnchor:statusBarView.leadingAnchor constant:8],
        [self.closeButton.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.closeButton.widthAnchor constraintEqualToConstant:30],
        [self.closeButton.heightAnchor constraintEqualToConstant:30],
        
        [self.minimizeButton.trailingAnchor constraintEqualToAnchor:statusBarView.trailingAnchor constant:-8],
        [self.minimizeButton.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.minimizeButton.widthAnchor constraintEqualToConstant:30],
        [self.minimizeButton.heightAnchor constraintEqualToConstant:30],
        
        [self.infoButton.trailingAnchor constraintEqualToAnchor:self.minimizeButton.leadingAnchor constant:-8],
        [self.infoButton.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.infoButton.widthAnchor constraintEqualToConstant:30],
        [self.infoButton.heightAnchor constraintEqualToConstant:30],
    ]];
}

- (void)setupControlButtons {
    // Barra de controles inferior
    UIView *controlBarView = [[UIView alloc] init];
    controlBarView.translatesAutoresizingMaskIntoConstraints = NO;
    controlBarView.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:controlBarView];
    
    [NSLayoutConstraint activateConstraints:@[
        [controlBarView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [controlBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [controlBarView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [controlBarView.heightAnchor constraintEqualToConstant:60],
    ]];
    
    // Stack view para controles
    self.controlsStackView = [[UIStackView alloc] init];
    self.controlsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.controlsStackView.distribution = UIStackViewDistributionFillEqually;
    self.controlsStackView.alignment = UIStackViewAlignmentCenter;
    self.controlsStackView.spacing = 10;
    [controlBarView addSubview:self.controlsStackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.controlsStackView.leadingAnchor constraintEqualToAnchor:controlBarView.leadingAnchor constant:10],
        [self.controlsStackView.trailingAnchor constraintEqualToAnchor:controlBarView.trailingAnchor constant:-10],
        [self.controlsStackView.centerYAnchor constraintEqualToAnchor:controlBarView.centerYAnchor],
        [self.controlsStackView.heightAnchor constraintEqualToConstant:40],
    ]];
    
    // Botão principal
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
    self.toggleButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0];
    self.toggleButton.layer.cornerRadius = 8;
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.toggleButton.contentEdgeInsets = UIEdgeInsetsMake(5, 10, 5, 10);
    
    // Adicionar botões ao stack view
    [self.controlsStackView addArrangedSubview:self.toggleButton];
    
    // Configurar constraints específicos para o botão principal
    [NSLayoutConstraint activateConstraints:@[
        [self.toggleButton.widthAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
}

- (void)setupLoadingIndicator {
    if (@available(iOS 13.0, *)) {
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.loadingIndicator.color = [UIColor whiteColor];
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        #pragma clang diagnostic pop
    }
    
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.contentView addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
}

- (void)setupGestureRecognizers {
    // Gesture para mover a janela
    self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:self.panGesture];
    
    // Adicionar double tap para minimizar/maximizar
    [self addDoubleTapGesture];
}

- (void)setupGradients {
    // Gradiente para topo
    CAGradientLayer *topGradient = [CAGradientLayer layer];
    topGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0.7] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor]
    ];
    topGradient.locations = @[@0.0, @1.0];
    topGradient.startPoint = CGPointMake(0.5, 0.0);
    topGradient.endPoint = CGPointMake(0.5, 1.0);
    topGradient.frame = CGRectMake(0, 0, self.bounds.size.width, 60);
    [self.contentView.layer insertSublayer:topGradient atIndex:0];
    
    // Gradiente para base
    CAGradientLayer *bottomGradient = [CAGradientLayer layer];
    bottomGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0.7] CGColor]
    ];
    bottomGradient.locations = @[@0.0, @1.0];
    bottomGradient.startPoint = CGPointMake(0.5, 0.0);
    bottomGradient.endPoint = CGPointMake(0.5, 1.0);
    bottomGradient.frame = CGRectMake(0, self.bounds.size.height - 60, self.bounds.size.width, 60);
    [self.contentView.layer insertSublayer:bottomGradient atIndex:0];
}

#pragma mark - Public Methods

- (void)show {
    self.hidden = NO;
    [self makeKeyAndVisible];
    
    // Animação de entrada
    self.transform = CGAffineTransformMakeScale(0.7, 0.7);
    self.alpha = 0;
    
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1;
    } completion:nil];
    
    writeLog(@"[FloatingWindow] Janela flutuante mostrada com animação");
}

- (void)hide {
    [self stopPreview];
    
    // Animação de saída
    [UIView animateWithDuration:0.2 animations:^{
        self.transform = CGAffineTransformMakeScale(0.7, 0.7);
        self.alpha = 0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
    }];
    
    writeLog(@"[FloatingWindow] Janela flutuante ocultada com animação");
}

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
        [sender setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0];
        self.isPreviewActive = NO;
    } else {
        [self startPreview];
        [sender setTitle:@"Desativar Preview" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
        self.isPreviewActive = YES;
    }
}

- (void)startPreview {
    self.statusLabel.text = @"Conectando...";
    writeLog(@"[FloatingWindow] Iniciando preview");
    
    // Mostrar indicador de carregamento
    [self.loadingIndicator startAnimating];
    
    // Verificar se WebRTCManager está pronto
    if (!self.webRTCManager) {
        writeLog(@"[FloatingWindow] ERRO: WebRTCManager não inicializado");
        [self updateConnectionStatus:@"Erro: Gerenciador não inicializado"];
        [self.loadingIndicator stopAnimating];
        return;
    }
    
    // Definir isPreviewActive para true ANTES de iniciar WebRTC
    self.isPreviewActive = YES;
    
    // Iniciar WebRTC com tratamento de erro
    @try {
        [self.webRTCManager startWebRTC];
    } @catch (NSException *exception) {
        writeLog(@"[FloatingWindow] Exceção ao iniciar WebRTC: %@", exception);
        self.isPreviewActive = NO;
        [self.loadingIndicator stopAnimating];
        [self updateConnectionStatus:@"Erro ao iniciar conexão"];
        return;
    }
    
    // Atualizar UI para modo conectado
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    }];
}

- (void)stopPreview {
    // Parar WebRTC
    [self.webRTCManager stopWebRTC:YES];
    
    // Parar indicador de carregamento
    [self.loadingIndicator stopAnimating];
    
    // Atualizar status
    [self updateConnectionStatus:@"Desconectado"];
    
    // Atualizar UI para modo desconectado
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    }];
    
    writeLog(@"[FloatingWindow] Preview parado");
}

- (void)updateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

#pragma mark - Window Management Methods

- (void)changeWindowState:(FloatingWindowState)newState animated:(BOOL)animated {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    
    switch (newState) {
        case FloatingWindowStateMinimized: {
            // Salvar frame original ao minimizar
            if (self.windowState != FloatingWindowStateMinimized) {
                self.originalFrame = self.frame;
            }
            
            // Tamanho minimizado - um círculo pequeno
            CGFloat size = 60;
            CGRect minimizedFrame = CGRectMake(
                self.frame.origin.x,
                self.frame.origin.y,
                size,
                size
            );
            
            if (animated) {
                [UIView animateWithDuration:0.3 animations:^{
                    self.frame = minimizedFrame;
                    self.layer.cornerRadius = size / 2; // Círculo perfeito
                }];
            } else {
                self.frame = minimizedFrame;
                self.layer.cornerRadius = size / 2;
            }
            
            self.windowState = newState;
            break;
        }
            
        case FloatingWindowStateNormal: {
            CGRect newFrame;
            
            // Restaurar o tamanho original se vindo do estado minimizado
            if (self.windowState == FloatingWindowStateMinimized) {
                newFrame = self.originalFrame;
            } else {
                // Tamanho padrão se vindo de outros estados
                CGFloat width = MIN(screenBounds.size.width * 0.7, 300);
                CGFloat height = width * 1.5;
                
                newFrame = CGRectMake(
                    (screenBounds.size.width - width) / 2,
                    (screenBounds.size.height - height) / 2,
                    width,
                    height
                );
            }
            
            if (animated) {
                [UIView animateWithDuration:0.3 animations:^{
                    self.frame = newFrame;
                    self.layer.cornerRadius = 12;
                }];
            } else {
                self.frame = newFrame;
                self.layer.cornerRadius = 12;
            }
            
            self.windowState = newState;
            break;
        }
            
        case FloatingWindowStateExpanded:
        case FloatingWindowStateFullscreen:
            // Implementação simplificada - tratamos como normal por enquanto
            [self changeWindowState:FloatingWindowStateNormal animated:animated];
            break;
    }
}

- (void)minimizeWindow:(BOOL)animated {
    [self changeWindowState:FloatingWindowStateMinimized animated:animated];
}

- (void)expandWindow:(BOOL)animated {
    [self changeWindowState:FloatingWindowStateNormal animated:animated];
}

#pragma mark - Timer Management

- (void)resetAutoHideTimer {
    // Implementação simplificada - não auto-oculta controles
}

#pragma mark - Gesture Handlers

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.lastPosition = self.center;
            self.dragInProgress = YES;
            break;
            
        case UIGestureRecognizerStateChanged: {
            CGPoint newCenter = CGPointMake(self.lastPosition.x + translation.x,
                                            self.lastPosition.y + translation.y);
            
            // Garantir que a janela não saia completamente da tela
            CGRect bounds = [UIScreen mainScreen].bounds;
            CGFloat halfWidth = self.bounds.size.width / 2;
            CGFloat halfHeight = self.bounds.size.height / 2;
            
            // Limitar X
            if (newCenter.x - halfWidth < 0) {
                newCenter.x = halfWidth;
            } else if (newCenter.x + halfWidth > bounds.size.width) {
                newCenter.x = bounds.size.width - halfWidth;
            }
            
            // Limitar Y
            if (newCenter.y - halfHeight < 0) {
                newCenter.y = halfHeight;
            } else if (newCenter.y + halfHeight > bounds.size.height) {
                newCenter.y = bounds.size.height - halfHeight;
            }
            
            self.center = newCenter;
            break;
        }
            
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            self.dragInProgress = NO;
            break;
            
        default:
            break;
    }
}

- (void)addDoubleTapGesture {
    // Gesture de duplo toque para minimizar/maximizar
    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    self.doubleTapGesture.numberOfTapsRequired = 2;
    [self addGestureRecognizer:self.doubleTapGesture];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    // Alternar entre estados quando houver duplo toque
    if (self.windowState == FloatingWindowStateMinimized) {
        [self changeWindowState:FloatingWindowStateNormal animated:YES];
    } else {
        [self changeWindowState:FloatingWindowStateMinimized animated:YES];
    }
}

#pragma mark - RTCVideoViewDelegate

- (void)videoView:(RTCMTLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    writeLog(@"[FloatingWindow] Tamanho do vídeo alterado para: %@", NSStringFromCGSize(size));
    self.lastFrameSize = size;
    
    // Se estiver recebendo o primeiro frame válido, parar o indicador de carregamento
    if (size.width > 0 && size.height > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            
            // Atualizar feedback visual para o usuário
            [self updateConnectionStatus:[NSString stringWithFormat:@"Recebendo %dx%d", (int)size.width, (int)size.height]];
        });
    }
}

#pragma mark - Button Actions

- (void)closeButtonTapped {
    [self hide];
}

- (void)minimizeButtonTapped {
    // Alternar entre minimizado e normal
    if (self.windowState == FloatingWindowStateMinimized) {
        [self changeWindowState:FloatingWindowStateNormal animated:YES];
    } else {
        [self changeWindowState:FloatingWindowStateMinimized animated:YES];
    }
}

- (void)infoButtonTapped {
    // Simplificado - apenas mostra um alerta com informações
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateConnectionStatus:@"WebRTC Preview"];
    });
}

@end
