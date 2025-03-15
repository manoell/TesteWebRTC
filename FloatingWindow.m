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
        
        // Atualizar a cor da bolinha quando minimizada
        [self updateAssistiveTouchColor];
    } else {
        // Verificar se WebRTCManager existe
        if (!self.webRTCManager) {
            writeErrorLog(@"[FloatingWindow] WebRTCManager não inicializado");
            return;
        }
        
        [self startPreview];
        [sender setTitle:@"Desativar Preview" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
        self.isPreviewActive = YES;
        
        // Atualizar a cor da bolinha quando minimizada
        [self updateAssistiveTouchColor];
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
    writeLog(@"[FloatingWindow] Parando preview");
    
    // Verificar o webRTCManager
    if (!self.webRTCManager) {
        writeErrorLog(@"[FloatingWindow] stopPreview: WebRTCManager não inicializado");
        return;
    }
    
    // Tentar enviar mensagem bye
    @try {
        writeLog(@"[FloatingWindow] Enviando 'bye' via sendByeMessage");
        [self.webRTCManager sendByeMessage];
        
        // Pequeno delay para garantir que a mensagem seja enviada antes de fechar
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Agora sim parar o WebRTC
            writeLog(@"[FloatingWindow] Chamando stopWebRTC após tentativa de envio de 'bye'");
            [self.webRTCManager stopWebRTC:YES];
        });
    } @catch (NSException *exception) {
        writeErrorLog(@"[FloatingWindow] Exceção ao enviar bye: %@", exception);
        // Em caso de exceção, tentar diretamente stopWebRTC
        [self.webRTCManager stopWebRTC:YES];
    }
    
    // Parar indicador de carregamento
    [self.loadingIndicator stopAnimating];
    
    // Atualizar status
    [self updateConnectionStatus:@"Desconectado"];
    
    // Atualizar UI para modo desconectado
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    }];
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

- (void)setWindowState:(FloatingWindowState)newState {
    // Salvar estado anterior para transição
    FloatingWindowState oldState = _windowState;
    _windowState = newState;  // Use a variável de instância diretamente
    
    // Aplicar mudanças de estado imediatamente
    [self applyStateChanges:oldState toState:newState];
    
    // Atualizar controles baseado no novo estado
    [self updateControlsForState:newState];
    
    // Reset timer para auto-ocultar controles
    [self resetAutoHideTimer];
    
    writeLog(@"[FloatingWindow] Estado da janela alterado para: %d", (int)newState);
}

- (void)updateMinimizedAppearance {
    // Verificar se estamos no estado minimizado
    if (self.windowState != FloatingWindowStateMinimized) {
        return;
    }
    
    // Verificar se o webRTCManager existe
    if (!self.webRTCManager) {
        return;
    }
    
    // Definir a cor de fundo baseada no estado da conexão
    if (self.isPreviewActive) {
        // Verde quando conectado
        self.backgroundColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:0.8];
    } else {
        // Vermelho quando desconectado
        self.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:0.8];
    }
    
    // Verificar se já existe o ícone de câmera, se não, criar
    UIImageView *cameraIcon = [self viewWithTag:9999];
    if (!cameraIcon) {
        // Criar ícone com símbolo de câmera
        UIImage *image = [UIImage systemImageNamed:@"camera.fill"];
        if (!image) {
            // Fallback para iOS anterior ao 13
            image = [UIImage imageNamed:@"camera"];
        }
        
        cameraIcon = [[UIImageView alloc] initWithImage:image];
        cameraIcon.tag = 9999;
        cameraIcon.contentMode = UIViewContentModeScaleAspectFit;
        cameraIcon.tintColor = [UIColor whiteColor];
        [self addSubview:cameraIcon];
    }
    
    // Centralizar e dimensionar o ícone
    CGFloat iconSize = self.bounds.size.width * 0.6; // 60% do tamanho da bolinha
    cameraIcon.frame = CGRectMake(
        (self.bounds.size.width - iconSize) / 2,
        (self.bounds.size.height - iconSize) / 2,
        iconSize,
        iconSize
    );
    cameraIcon.hidden = NO;
}

- (void)applyStateChanges:(FloatingWindowState)fromState toState:(FloatingWindowState)toState {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    
    switch (toState) {
        case FloatingWindowStateMinimized: {
            // Salvar frame original ao minimizar
            if (fromState != FloatingWindowStateMinimized) {
                self.originalFrame = self.frame;
            }
            
            // Tamanho para modo AssistiveTouch
            CGFloat size = 50;  // Bolinha menor
            
            // Posicionar próximo à borda direita (padrão do AssistiveTouch)
            CGFloat rightPadding = 20;
            CGFloat middleY = screenBounds.size.height / 2;
            
            CGRect minimizedFrame = CGRectMake(
                screenBounds.size.width - size - rightPadding,
                middleY - size/2,
                size,
                size
            );
            
            // Ajustar frame
            self.frame = minimizedFrame;
            self.layer.cornerRadius = size / 2;
            
            // Adicionar sombra sutil
            self.layer.shadowColor = [UIColor blackColor].CGColor;
            self.layer.shadowOffset = CGSizeMake(0, 3);
            self.layer.shadowOpacity = 0.3;
            self.layer.shadowRadius = 3;
            
            // Ajustar opacidade para ficar semitransparente como AssistiveTouch
            self.alpha = 0.8;
            
            // Esconder todas as subviews
            for (UIView *subview in self.contentView.subviews) {
                subview.hidden = YES;
            }
            
            // Cor vermelha por padrão (sem conexão)
            self.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.8];
            
            // Criar ícone de câmera
            [self createCameraIconForAssistiveMode];
            
            writeLog(@"[FloatingWindow] Aplicado estilo AssistiveTouch em modo minimizado");
        }
        break;
            
        case FloatingWindowStateNormal: {
            // Voltar à opacidade normal
            self.alpha = 1.0;
            
            // Restaurar para o tamanho original
            if (fromState == FloatingWindowStateMinimized) {
                // Remover ícone de câmera
                UIView *cameraIcon = [self viewWithTag:9999];
                if (cameraIcon) {
                    [cameraIcon removeFromSuperview];
                }
                
                // Restaurar frame original
                self.frame = self.originalFrame;
                
                // Mostrar novamente todas as subviews
                for (UIView *subview in self.contentView.subviews) {
                    subview.hidden = NO;
                }
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
            
            // Restaurar aparência
            self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
            self.layer.cornerRadius = 12;
        }
        break;
            
        case FloatingWindowStateExpanded: {
            // Voltar à opacidade normal
            self.alpha = 1.0;
            
            // Remover ícone de câmera
            UIView *cameraIcon = [self viewWithTag:9999];
            if (cameraIcon) {
                [cameraIcon removeFromSuperview];
            }
            
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
            
            // Mostrar todas as subviews
            for (UIView *subview in self.contentView.subviews) {
                subview.hidden = NO;
            }
        }
        break;
            
        case FloatingWindowStateFullscreen: {
            // Voltar à opacidade normal
            self.alpha = 1.0;
            
            // Remover ícone de câmera
            UIView *cameraIcon = [self viewWithTag:9999];
            if (cameraIcon) {
                [cameraIcon removeFromSuperview];
            }
            
            // Tela cheia - ocupa toda a tela com pequena borda
            CGFloat padding = 20;
            CGRect fullscreenFrame = CGRectInset(screenBounds, padding, padding);
            
            self.frame = fullscreenFrame;
            self.layer.cornerRadius = 12;
            
            // Mostrar todas as subviews
            for (UIView *subview in self.contentView.subviews) {
                subview.hidden = NO;
            }
        }
        break;
    }
}

// Criar ícone de câmera para modo AssistiveTouch
- (void)createCameraIconForAssistiveMode {
    // Remover qualquer ícone existente
    UIView *existingIcon = [self viewWithTag:9999];
    if (existingIcon) {
        [existingIcon removeFromSuperview];
    }
    
    // Criar um container para o ícone da câmera
    UIView *iconContainer = [[UIView alloc] init];
    iconContainer.tag = 9999;
    [self addSubview:iconContainer];
    
    // Centralizar o container
    CGFloat size = self.bounds.size.width * 0.6; // 60% do tamanho da bolinha
    iconContainer.frame = CGRectMake(
        (self.bounds.size.width - size) / 2,
        (self.bounds.size.height - size) / 2,
        size,
        size
    );
    
    // Adicionar um desenho de câmera simples usando camadas
    CAShapeLayer *cameraLayer = [CAShapeLayer layer];
    cameraLayer.frame = iconContainer.bounds;
    cameraLayer.fillColor = [UIColor whiteColor].CGColor;
    
    // Desenhar o corpo da câmera
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGRect bodyRect = CGRectInset(iconContainer.bounds, size * 0.1, size * 0.2);
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:bodyRect cornerRadius:3]];
    
    // Desenhar a lente
    CGFloat lensSize = size * 0.4;
    CGRect lensRect = CGRectMake(
        (iconContainer.bounds.size.width - lensSize) / 2,
        (iconContainer.bounds.size.height - lensSize) / 2,
        lensSize,
        lensSize
    );
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:lensRect]];
    
    // Desenhar o flash
    CGRect flashRect = CGRectMake(
        iconContainer.bounds.size.width * 0.7,
        iconContainer.bounds.size.height * 0.2,
        size * 0.15,
        size * 0.1
    );
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:flashRect cornerRadius:2]];
    
    cameraLayer.path = path.CGPath;
    [iconContainer.layer addSublayer:cameraLayer];
}

// Atualizar a cor da bolinha com base no estado de conexão
- (void)updateAssistiveTouchColor {
    // Verificar se estamos no estado minimizado
    if (self.windowState != FloatingWindowStateMinimized) {
        return;
    }
    
    // Atualizar cor com base no estado da conexão
    if (self.isPreviewActive) {
        // Verde quando conectado (streaming)
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.8];
        writeLog(@"[FloatingWindow] Atualizando cor para verde (conectado)");
    } else {
        // Vermelho quando desconectado
        self.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.8];
        writeLog(@"[FloatingWindow] Atualizando cor para vermelho (desconectado)");
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

// Manipulador de arrasto melhorado para modo AssistiveTouch
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.lastPosition = self.center;
            self.dragInProgress = YES;
            // Aumentar levemente a opacidade durante o arrasto
            if (self.windowState == FloatingWindowStateMinimized) {
                [UIView animateWithDuration:0.2 animations:^{
                    self.alpha = 1.0;
                }];
            }
            writeLog(@"[FloatingWindow] Iniciando arrasto, estado=%d", (int)self.windowState);
            break;
            
        case UIGestureRecognizerStateChanged: {
            // Nova posição com base na tradução do gesto
            CGPoint newCenter = CGPointMake(self.lastPosition.x + translation.x,
                                           self.lastPosition.y + translation.y);
            
            // Limites da tela
            CGRect screenBounds = [UIScreen mainScreen].bounds;
            
            // Comportamento especial para modo minimizado (AssistiveTouch)
            if (self.windowState == FloatingWindowStateMinimized) {
                // Calcular o raio da bolinha
                CGFloat radius = self.frame.size.width / 2.0;
                
                // Garantir que a bolinha fique dentro da tela
                CGFloat minX = radius;
                CGFloat maxX = screenBounds.size.width - radius;
                CGFloat minY = radius;
                CGFloat maxY = screenBounds.size.height - radius;
                
                // Aplicar limites
                if (newCenter.x < minX) newCenter.x = minX;
                if (newCenter.x > maxX) newCenter.x = maxX;
                if (newCenter.y < minY) newCenter.y = minY;
                if (newCenter.y > maxY) newCenter.y = maxY;
            } else {
                // Para outros estados, manter a janela inteira dentro da tela
                CGFloat halfWidth = self.frame.size.width / 2;
                CGFloat halfHeight = self.frame.size.height / 2;
                
                if (newCenter.x - halfWidth < 0) {
                    newCenter.x = halfWidth;
                } else if (newCenter.x + halfWidth > screenBounds.size.width) {
                    newCenter.x = screenBounds.size.width - halfWidth;
                }
                
                if (newCenter.y - halfHeight < 0) {
                    newCenter.y = halfHeight;
                } else if (newCenter.y + halfHeight > screenBounds.size.height) {
                    newCenter.y = screenBounds.size.height - halfHeight;
                }
            }
            
            // Atualizar a posição
            self.center = newCenter;
            
            writeLog(@"[FloatingWindow] Arrastando para: %@", NSStringFromCGPoint(newCenter));
            break;
        }
            
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            self.dragInProgress = NO;
            
            // Restaurar a opacidade normal quando no modo minimizado
            if (self.windowState == FloatingWindowStateMinimized) {
                [UIView animateWithDuration:0.2 animations:^{
                    self.alpha = 0.8;
                }];
                
                // Snap para a borda mais próxima
                [self snapAssistiveTouchToBorder];
            }
            
            writeLog(@"[FloatingWindow] Arrasto finalizado");
            break;
            
        default:
            break;
    }
}

// Novo método para snap da bolinha AssistiveTouch
- (void)snapAssistiveTouchToBorder {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGPoint center = self.center;
    CGFloat radius = self.frame.size.width / 2.0;
    
    // Verificar qual borda está mais próxima
    CGFloat distanceToLeft = center.x;
    CGFloat distanceToRight = screenBounds.size.width - center.x;
    
    // Manter o Y atual, mas ajustar o X para a borda mais próxima
    if (distanceToLeft < distanceToRight) {
        // Snap para a borda esquerda
        center.x = radius + 5; // Pequena margem
    } else {
        // Snap para a borda direita
        center.x = screenBounds.size.width - radius - 5; // Pequena margem
    }
    
    // Animar o movimento para a borda
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.center = center;
    } completion:nil];
    
    writeLog(@"[FloatingWindow] Snap para borda: %@", NSStringFromCGPoint(center));
}

// Método para "colar" a bolinha minimizada à borda da tela
- (void)snapToEdge {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGPoint center = self.center;
    CGFloat radius = self.frame.size.width / 2.0;
    
    // Calcular distâncias às bordas
    CGFloat distanceToLeft = center.x;
    CGFloat distanceToRight = screenBounds.size.width - center.x;
    CGFloat distanceToTop = center.y;
    CGFloat distanceToBottom = screenBounds.size.height - center.y;
    
    // Encontrar a borda mais próxima
    CGFloat minDistance = MIN(MIN(distanceToLeft, distanceToRight),
                             MIN(distanceToTop, distanceToBottom));
    
    // Definir nova posição
    if (minDistance == distanceToLeft) {
        // Snap para esquerda
        center.x = 0 + radius * 0.5; // 50% visível
    } else if (minDistance == distanceToRight) {
        // Snap para direita
        center.x = screenBounds.size.width - radius * 0.5;
    } else if (minDistance == distanceToTop) {
        // Snap para topo
        center.y = 0 + radius * 0.5;
    } else if (minDistance == distanceToBottom) {
        // Snap para base
        center.y = screenBounds.size.height - radius * 0.5;
    }
    
    // Animar movimento
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.center = center;
    } completion:nil];
    
    writeLog(@"[FloatingWindow] Snap para borda: %@", NSStringFromCGPoint(center));
}

// Manipulador de duplo toque melhorado
- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    writeLog(@"[FloatingWindow] Duplo toque detectado no estado %d", (int)self.windowState);
    
    switch (self.windowState) {
        case FloatingWindowStateMinimized:
            // Expandir direto para tela cheia
            [self changeWindowState:FloatingWindowStateFullscreen animated:YES];
            break;
            
        case FloatingWindowStateNormal:
        case FloatingWindowStateExpanded:
            // Expandir para tela cheia
            [self changeWindowState:FloatingWindowStateFullscreen animated:YES];
            break;
            
        case FloatingWindowStateFullscreen:
            // Voltar para minimizado
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

// Novo método para snap à borda quando minimizado
- (void)snapMinimizedToBorder:(BOOL)animated {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat radius = self.bounds.size.width / 2.0;
    CGPoint targetPoint = self.center;
    
    // Calcular qual borda está mais próxima
    CGFloat distanceToLeft = self.center.x;
    CGFloat distanceToRight = screenBounds.size.width - self.center.x;
    CGFloat distanceToTop = self.center.y;
    CGFloat distanceToBottom = screenBounds.size.height - self.center.y;
    
    CGFloat minDistance = MIN(MIN(distanceToLeft, distanceToRight),
                           MIN(distanceToTop, distanceToBottom));
    
    // Alinhar com a borda mais próxima, deixando a bolinha parcialmente visível
    if (minDistance == distanceToLeft) {
        // Snap para borda esquerda
        targetPoint.x = radius * 0.2; // 20% visível
    } else if (minDistance == distanceToRight) {
        // Snap para borda direita
        targetPoint.x = screenBounds.size.width - radius * 0.2;
    } else if (minDistance == distanceToTop) {
        // Snap para borda superior
        targetPoint.y = radius * 0.2;
    } else if (minDistance == distanceToBottom) {
        // Snap para borda inferior
        targetPoint.y = screenBounds.size.height - radius * 0.2;
    }
    
    // Se o ponto não mudou, não precisa animar
    if (CGPointEqualToPoint(targetPoint, self.center)) {
        return;
    }
    
    // Animar o movimento
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
