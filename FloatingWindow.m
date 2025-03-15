#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()

// UI Components
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UIButton *minimizeButton;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic, strong) UIStackView *controlsStackView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;

// State tracking
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, assign) CGRect originalFrame;
@property (nonatomic, assign) CGSize lastFrameSize;
@property (nonatomic, assign) BOOL dragInProgress;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic, assign) BOOL controlsVisible;

// RTCMTLVideoView para renderização
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
        
        // Configuração da sombra
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        
        [self setupUI];
        
        // Inicializar WebRTC manager
        self.webRTCManager = [[WebRTCManager alloc] initWithFloatingWindow:self];
        
        // Estado inicial
        self.isPreviewActive = NO;
        self.controlsVisible = YES;
        self.lastFrameSize = CGSizeZero;
        self.isTranslucent = YES;
        self.isReceivingFrames = NO;
        self.currentFps = 0;
        
        // Iniciar temporizador para auto-ocultar controles
        [self resetAutoHideTimer];
        
        writeLog(@"[FloatingWindow] Janela flutuante inicializada com UI aprimorada e RTCMTLVideoView");
    }
    return self;
}

- (void)setupUI {
    // Container principal
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
    
    // Configurar componentes da UI
    [self setupVideoView];
    [self setupStatusBar];
    [self setupControlButtons];
    [self setupLoadingIndicator];
    [self setupGestureRecognizers];
    [self setupGradients];
}

- (void)setupVideoView {
    // Usar RTCMTLVideoView para renderização eficiente de vídeo
    self.videoView = [[RTCMTLVideoView alloc] init];
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
    
    writeLog(@"[FloatingWindow] RTCMTLVideoView configurada com sucesso");
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
    
    // Botão de minimizar
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.minimizeButton.trailingAnchor constraintEqualToAnchor:statusBarView.trailingAnchor constant:-8],
        [self.minimizeButton.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.minimizeButton.widthAnchor constraintEqualToConstant:30],
        [self.minimizeButton.heightAnchor constraintEqualToConstant:30],
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
    
    // Adicionar botão ao stack view
    [self.controlsStackView addArrangedSubview:self.toggleButton];
    
    // Configurar constraints específicos para o botão principal
    [NSLayoutConstraint activateConstraints:@[
        [self.toggleButton.widthAnchor constraintGreaterThanOrEqualToConstant:180],
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
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:panGesture];
    
    // Adicionar double tap para minimizar/maximizar
    UITapGestureRecognizer *doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTapGesture.numberOfTapsRequired = 2;
    [self addGestureRecognizer:doubleTapGesture];
    
    // Tap para mostrar/ocultar controles
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
    tapGesture.numberOfTapsRequired = 1;
    [self addGestureRecognizer:tapGesture];
    
    // Evitar conflitos entre gestures
    [panGesture requireGestureRecognizerToFail:tapGesture];
    [tapGesture requireGestureRecognizerToFail:doubleTapGesture];
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
    
    self.gradientLayer = [CAGradientLayer layer];
    self.gradientLayer.colors = @[
        (id)[[UIColor colorWithRed:0.1 green:0.1 blue:0.2 alpha:0.9] CGColor],
        (id)[[UIColor colorWithRed:0.0 green:0.1 blue:0.3 alpha:0.8] CGColor]
    ];
    self.gradientLayer.frame = self.bounds;
    [self.layer insertSublayer:self.gradientLayer atIndex:0];
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
    
    // Iniciar WebRTC com tratamento de erro
    @try {
        if (!self.webRTCManager) {
            writeErrorLog(@"[FloatingWindow] ERRO: WebRTCManager não inicializado");
            [self updateConnectionStatus:@"Erro: Gerenciador não inicializado"];
            [self.loadingIndicator stopAnimating];
            return;
        }
        
        [self.webRTCManager startWebRTC];
    } @catch (NSException *exception) {
        writeErrorLog(@"[FloatingWindow] Exceção ao iniciar WebRTC: %@", exception);
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
        // Para status de recepção, mostrar resolução e FPS
        if ([status containsString:@"Recebendo"] ||
            [status containsString:@"Conectado"]) {
            if (self.isReceivingFrames) {
                if (self.lastFrameSize.width > 0 && self.lastFrameSize.height > 0) {
                    NSString *dimensionString = [NSString stringWithFormat:@"%dx%d",
                                                (int)self.lastFrameSize.width,
                                                (int)self.lastFrameSize.height];
                    
                    if (self.currentFps > 0) {
                        self.statusLabel.text = [NSString stringWithFormat:@"Recebendo %@ @ %dfps",
                                               dimensionString, (int)self.currentFps];
                    } else {
                        self.statusLabel.text = [NSString stringWithFormat:@"Recebendo %@",
                                               dimensionString];
                    }
                } else {
                    self.statusLabel.text = @"Conectado - Recebendo stream";
                }
            } else {
                self.statusLabel.text = status;
            }
        } else {
            self.statusLabel.text = status;
        }
    });
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
            
            // Se temos informação de FPS, vamos tentar usar
            if (self.webRTCManager && [self.webRTCManager respondsToSelector:@selector(getEstimatedFps)]) {
                self.currentFps = [self.webRTCManager getEstimatedFps];
                // Forçar atualização do status para incluir FPS
                [self updateConnectionStatus:[NSString stringWithFormat:@"Recebendo %dx%d", (int)size.width, (int)size.height]];
            }
        });
    }
}

#pragma mark - Window State Management

- (void)minimizeButtonTapped {
    // Alternar entre minimizado e normal
    if (self.windowState == FloatingWindowStateMinimized) {
        [self changeWindowState:FloatingWindowStateNormal animated:YES];
    } else {
        [self changeWindowState:FloatingWindowStateMinimized animated:YES];
    }
}

- (void)changeWindowState:(FloatingWindowState)newState animated:(BOOL)animated {
    // Salvar estado anterior para transição
    FloatingWindowState oldState = self.windowState;
    self.windowState = newState;
    
    if (animated) {
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            [self applyStateChanges:oldState toState:newState];
        } completion:nil];
    } else {
        [self applyStateChanges:oldState toState:newState];
    }
    
    // Atualizar controles baseado no novo estado
    [self updateControlsForState:newState];
    
    // Reset timer para auto-ocultar controles
    [self resetAutoHideTimer];
}

- (void)applyStateChanges:(FloatingWindowState)fromState toState:(FloatingWindowState)toState {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    
    switch (toState) {
        case FloatingWindowStateMinimized: {
            // Salvar frame original ao minimizar
            if (fromState != FloatingWindowStateMinimized) {
                self.originalFrame = self.frame;
            }
            
            // Tamanho minimizado - um círculo pequeno
            CGFloat size = 60;
            
            // Manter a posição X/Y mas ajustar tamanho
            CGRect minimizedFrame = CGRectMake(
                self.frame.origin.x,
                self.frame.origin.y,
                size,
                size
            );
            
            // Garantir que está dentro da tela
            if (CGRectGetMaxX(minimizedFrame) > screenBounds.size.width) {
                minimizedFrame.origin.x = screenBounds.size.width - minimizedFrame.size.width;
            }
            
            if (CGRectGetMaxY(minimizedFrame) > screenBounds.size.height) {
                minimizedFrame.origin.y = screenBounds.size.height - minimizedFrame.size.height;
            }
            
            self.frame = minimizedFrame;
            self.layer.cornerRadius = size / 2; // Círculo perfeito
        }
            break;
            
        case FloatingWindowStateNormal:
            // Restaurar para o tamanho original
            if (fromState == FloatingWindowStateMinimized) {
                self.frame = self.originalFrame;
            } else {
                // Tamanho padrão se vier de outros estados
                CGFloat width = MIN(screenBounds.size.width * 0.7, 300);
                CGFloat height = width * 1.5;
                
                CGRect normalFrame = CGRectMake(
                    (screenBounds.size.width - width) / 2,
                    (screenBounds.size.height - height) / 2,
                    width,
                    height
                );
                
                self.frame = normalFrame;
            }
            self.layer.cornerRadius = 12;
            break;
            
        case FloatingWindowStateExpanded: {
            // Tamanho expandido - ocupar mais espaço com controles visíveis
            CGFloat padding = 40;
            CGFloat width = MIN(screenBounds.size.width - padding * 2, 400);
            CGFloat height = width * 1.4;
            
            CGRect expandedFrame = CGRectMake(
                (screenBounds.size.width - width) / 2,
                (screenBounds.size.height - height) / 2,
                width,
                height
            );
            
            self.frame = expandedFrame;
            self.layer.cornerRadius = 12;
        }
            break;
            
        case FloatingWindowStateFullscreen: {
            // Tela cheia - ocupa toda a tela com pequena borda
            CGFloat padding = 20;
            CGRect fullscreenFrame = CGRectInset(screenBounds, padding, padding);
            
            self.frame = fullscreenFrame;
            self.layer.cornerRadius = 12;
        }
            break;
    }
}

- (void)updateControlsForState:(FloatingWindowState)state {
    // Atualizar visibilidade e estilo dos controles baseado no estado
    switch (state) {
        case FloatingWindowStateMinimized:
            // Em modo minimizado, esconder a maioria dos controles
            [self hideControlsAnimated:NO];
            break;
            
        case FloatingWindowStateNormal:
        case FloatingWindowStateExpanded:
            // Mostrar controles normais
            [self showControlsAnimated:NO];
            break;
            
        case FloatingWindowStateFullscreen:
            // Mostrar controles extras no modo fullscreen
            [self showControlsAnimated:NO];
            break;
    }
}

#pragma mark - UI Control Methods

- (void)showControlsAnimated:(BOOL)animated {
    if (self.windowState == FloatingWindowStateMinimized) {
        return;
    }
    
    self.controlsVisible = YES;
    [self invalidateAutoHideTimer];
    
    void (^showAnimations)(void) = ^{
        self.minimizeButton.alpha = 1.0;
        self.controlsStackView.alpha = 1.0;
        self.statusLabel.alpha = 1.0;
    };
    
    if (animated) {
        [UIView animateWithDuration:0.3 animations:showAnimations];
    } else {
        showAnimations();
    }
    
    [self resetAutoHideTimer];
}

- (void)hideControlsAnimated:(BOOL)animated {
    self.controlsVisible = NO;
    
    void (^hideAnimations)(void) = ^{
        self.minimizeButton.alpha = 0.0;
        self.controlsStackView.alpha = 0.0;
        
        // Manter status parcialmente visível
        self.statusLabel.alpha = 0.7;
    };
    
    if (animated) {
        [UIView animateWithDuration:0.3 animations:hideAnimations];
    } else {
        hideAnimations();
    }
}

#pragma mark - Timer Management

- (void)resetAutoHideTimer {
    [self invalidateAutoHideTimer];
    
    // Apenas criar timer se estiver conectado e não estiver minimizado ou arrastando
    if (self.isPreviewActive && self.windowState != FloatingWindowStateMinimized && !self.dragInProgress) {
        self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                          target:self
                                                        selector:@selector(autoHideControls)
                                                        userInfo:nil
                                                         repeats:NO];
    }
}

- (void)invalidateAutoHideTimer {
    if (self.autoHideTimer) {
        [self.autoHideTimer invalidate];
        self.autoHideTimer = nil;
    }
}

- (void)autoHideControls {
    if (self.controlsVisible && !self.dragInProgress) {
        [self hideControlsAnimated:YES];
    }
}

#pragma mark - Gesture Handlers

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.lastPosition = self.center;
            self.dragInProgress = YES;
            // Não mostrar controles quando minimizado para garantir que não atrapalhem o gesto
            if (self.windowState != FloatingWindowStateMinimized) {
                [self showControlsAnimated:YES];
            }
            break;
            
        case UIGestureRecognizerStateChanged: {
            CGPoint newCenter = CGPointMake(self.lastPosition.x + translation.x,
                                           self.lastPosition.y + translation.y);
            
            // Garantir que a janela não saia completamente da tela
            CGRect bounds = [UIScreen mainScreen].bounds;
            
            // Cálculo especial para o modo minimizado
            if (self.windowState == FloatingWindowStateMinimized) {
                // No modo minimizado, permitir mais liberdade de movimento
                // Garantir que pelo menos 15px da janela fiquem visíveis
                float minVisiblePart = 15.0;
                float maxX = bounds.size.width - minVisiblePart;
                float maxY = bounds.size.height - minVisiblePart;
                
                if (newCenter.x < minVisiblePart) newCenter.x = minVisiblePart;
                if (newCenter.x > maxX) newCenter.x = maxX;
                if (newCenter.y < minVisiblePart) newCenter.y = minVisiblePart;
                if (newCenter.y > maxY) newCenter.y = maxY;
            } else {
                // Comportamento original para outros estados
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
            }
            
            self.center = newCenter;
            break;
        }
            
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            self.dragInProgress = NO;
            // Comportamento de snap opcional para o modo minimizado
            if (self.windowState != FloatingWindowStateMinimized) {
                [self snapToNearestCorner:YES];
            }
            [self resetAutoHideTimer];
            break;
            
        default:
            break;
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    // Alternar entre estados quando houver duplo toque
    switch (self.windowState) {
        case FloatingWindowStateMinimized:
            [self changeWindowState:FloatingWindowStateNormal animated:YES];
            break;
            
        case FloatingWindowStateNormal:
            [self changeWindowState:FloatingWindowStateFullscreen animated:YES];
            break;
            
        case FloatingWindowStateExpanded:
        case FloatingWindowStateFullscreen:
            [self changeWindowState:FloatingWindowStateMinimized animated:YES];
            break;
    }
}

- (void)handleSingleTap:(UITapGestureRecognizer *)gesture {
    // Mostrar/esconder controles com toque único
    if (self.controlsVisible) {
        [self hideControlsAnimated:YES];
    } else {
        [self showControlsAnimated:YES];
    }
}

- (void)snapToNearestCorner:(BOOL)animated {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat threshold = 100; // Distância para considerar "perto" da borda
    
    // Determinar qual borda está mais próxima
    CGFloat distanceToLeft = self.center.x;
    CGFloat distanceToRight = screenBounds.size.width - self.center.x;
    CGFloat distanceToTop = self.center.y;
    CGFloat distanceToBottom = screenBounds.size.height - self.center.y;
    
    CGFloat padding = 10.0;
    CGPoint targetPoint = self.center;
    
    // Primeiro determina horizontal
    if (distanceToLeft < threshold) {
        targetPoint.x = self.frame.size.width/2 + padding;
    } else if (distanceToRight < threshold) {
        targetPoint.x = screenBounds.size.width - self.frame.size.width/2 - padding;
    }
    
    // Depois determina vertical
    if (distanceToTop < threshold) {
        targetPoint.y = self.frame.size.height/2 + padding;
    } else if (distanceToBottom < threshold) {
        targetPoint.y = screenBounds.size.height - self.frame.size.height/2 - padding;
    }
    
    // Se o ponto não mudou, não precisa animar
    if (CGPointEqualToPoint(targetPoint, self.center)) {
        return;
    }
    
    if (animated) {
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            self.center = targetPoint;
        } completion:nil];
    } else {
        self.center = targetPoint;
    }
}

- (void)setWindowTranslucency:(BOOL)translucent {
    self.isTranslucent = translucent;
    
    if (translucent) {
        [UIView animateWithDuration:0.3 animations:^{
            self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
        }];
    } else {
        [UIView animateWithDuration:0.3 animations:^{
            self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0];
        }];
    }
}

@end
