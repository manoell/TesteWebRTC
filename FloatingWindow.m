#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, assign) NSTimeInterval lastImageUpdate;
@end

@implementation FloatingWindow

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
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
        self.layer.cornerRadius = 10;
        self.clipsToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
        
        // Incluir sombra para melhor aparência
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 3);
        self.layer.shadowOpacity = 0.4;
        self.layer.shadowRadius = 5;
        
        // Container principal
        self.contentView = [[UIView alloc] initWithFrame:self.bounds];
        self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:self.contentView];
        
        // Preview ImageView
        self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height - 50)];
        self.previewImageView.backgroundColor = [UIColor blackColor];
        self.previewImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.previewImageView.clipsToBounds = YES;
        [self.contentView addSubview:self.previewImageView];
        
        // Status Label
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, self.bounds.size.width - 20, 30)];
        self.statusLabel.text = @"WebRTC Preview";
        self.statusLabel.textColor = [UIColor whiteColor];
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        self.statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        self.statusLabel.layer.cornerRadius = 5;
        self.statusLabel.clipsToBounds = YES;
        self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
        [self.contentView addSubview:self.statusLabel];
        
        // Botão de controle
        self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.toggleButton.frame = CGRectMake(0, self.bounds.size.height - 50, self.bounds.size.width, 50);
        [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
        self.toggleButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0];
        self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        self.toggleButton.layer.borderWidth = 1;
        self.toggleButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
        [self.contentView addSubview:self.toggleButton];
        
        // Adicionar indicador de carregamento
        if (@available(iOS 13.0, *)) {
            self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            self.loadingIndicator.color = [UIColor whiteColor]; // Definir cor branca explicitamente
        } else {
            // Fallback para versões mais antigas do iOS com método não depreciado
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
            #pragma clang diagnostic pop
        }
        
        self.loadingIndicator.center = CGPointMake(self.bounds.size.width / 2, (self.bounds.size.height - 50) / 2);
        self.loadingIndicator.hidesWhenStopped = YES;
        [self.contentView addSubview:self.loadingIndicator];
        
        // Gesture recognizer para mover
        self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:self.panGesture];
        
        // Adicionar double tap para minimizar/maximizar
        [self addDoubleTapGesture];
        
        // Inicializar WebRTC manager
        self.webRTCManager = [[WebRTCManager alloc] initWithFloatingWindow:self];
        
        self.isPreviewActive = NO;
        self.lastImageUpdate = 0;
        
        writeLog(@"[FloatingWindow] Janela flutuante inicializada");
    }
    return self;
}

- (void)show {
    self.hidden = NO;
    [self makeKeyAndVisible];
    writeLog(@"[FloatingWindow] Janela flutuante mostrada");
}

- (void)hide {
    [self stopPreview];
    self.hidden = YES;
    writeLog(@"[FloatingWindow] Janela flutuante ocultada");
}

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
        [sender setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        self.isPreviewActive = NO;
    } else {
        [self startPreview];
        [sender setTitle:@"Desativar Preview" forState:UIControlStateNormal];
        self.isPreviewActive = YES;
    }
}

- (void)startPreview {
    self.statusLabel.text = @"Conectando...";
    writeLog(@"[FloatingWindow] Iniciando preview");
    
    // Mostrar indicador de carregamento
    [self.loadingIndicator startAnimating];
    
    // Limpar preview anterior
    self.previewImageView.image = nil;
    
    // Definir isPreviewActive para true ANTES de iniciar WebRTC
    self.isPreviewActive = YES;
    
    // Iniciar monitoramento de recebimento de frames
    [self startFrameMonitoring];
    
    // Iniciar WebRTC
    [self.webRTCManager startWebRTC];
}

- (void)startFrameMonitoring {
    // Monitorar se os frames estão chegando (a cada 5 segundos)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.isPreviewActive) {
            NSTimeInterval now = CACurrentMediaTime();
            if (now - self.lastImageUpdate > 5.0) {
                // Nenhum frame recebido por 5 segundos
                writeLog(@"[FloatingWindow] Alerta: Nenhum frame recebido nos últimos 5 segundos");
                [self updateConnectionStatus:@"Sem quadros recebidos"];
            }
            
            // Continuar monitoramento
            [self startFrameMonitoring];
        }
    });
}

- (void)updateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
        
        // Mudar a cor do label conforme o status
        if ([status containsString:@"Erro"] || [status containsString:@"Desconectado"] ||
            [status containsString:@"Sem"] || [status containsString:@"Problema"]) {
            self.statusLabel.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:0.7];
        } else if ([status containsString:@"Conectado"] || [status containsString:@"Stream"] ||
                   [status containsString:@"ativo"] || [status containsString:@"OK"] ||
                   [status containsString:@"x"]      // Para resoluções como "1920x1080"
                   ) {
            self.statusLabel.backgroundColor = [UIColor colorWithRed:0.0 green:0.7 blue:0.0 alpha:0.7];
        } else {
            self.statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        }
        
        // Parar indicador de carregamento se conectado ou erro
        if ([status containsString:@"Conectado"] || [status containsString:@"Erro"] ||
            [status containsString:@"Desconectado"] || [status containsString:@"ativo"] ||
            [status containsString:@"x"]) {
            [self.loadingIndicator stopAnimating];
        } else {
            [self.loadingIndicator startAnimating];
        }
        
        writeLog(@"[FloatingWindow] Status atualizado: %@", status);
    });
}

- (void)stopPreview {
    self.statusLabel.text = @"Desconectado";
    writeLog(@"[FloatingWindow] Parando preview");
    [self.webRTCManager stopWebRTC];
    self.previewImageView.image = nil;
    [self.loadingIndicator stopAnimating];
}

- (void)updatePreviewImage:(UIImage *)image {
    if (!image) {
        writeLog(@"[FloatingWindow] Tentativa de atualizar com imagem nula");
        return;
    }
    
    // Verificar dimensões
    if (image.size.width <= 0 || image.size.height <= 0) {
        writeLog(@"[FloatingWindow] Tentativa de atualizar com imagem de dimensões inválidas: %@",
                NSStringFromCGSize(image.size));
        return;
    }
    
    // Garantir execução na thread principal
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePreviewImage:image];
        });
        return;
    }
    
    // Verificar se o preview está ativo
    if (!self.isPreviewActive) {
        writeLog(@"[FloatingWindow] Preview não está ativo, ignorando atualização de imagem");
        return;
    }
    
    // Verificar se a image view existe
    if (!self.previewImageView) {
        writeLog(@"[FloatingWindow] PreviewImageView é nula");
        return;
    }
    
    @try {
        // Atualizar a imagem
        self.previewImageView.image = image;
        self.lastImageUpdate = CACurrentMediaTime();
        
        // Parar indicador de carregamento quando imagem é recebida
        if (self.loadingIndicator && [self.loadingIndicator isAnimating]) {
            [self.loadingIndicator stopAnimating];
        }
        
        static int updateCount = 0;
        updateCount++;
        
        if (updateCount == 1) {
            writeLog(@"[FloatingWindow] Primeira imagem recebida: %dx%d",
                     (int)image.size.width,
                     (int)image.size.height);
            
            // Atualizar status
            [self updateConnectionStatus:@"Stream ativo"];
        }
        
        // Log a cada 100 frames para verificar continuidade
        if (updateCount % 100 == 0) {
            writeLog(@"[FloatingWindow] Recebido frame #%d: %dx%d",
                    updateCount,
                    (int)image.size.width,
                    (int)image.size.height);
        }
        
        // Verificar tamanho da imagem - se muito pequena, pode ser um problema
        if (image.size.width < 100 || image.size.height < 100) {
            writeLog(@"[FloatingWindow] AVISO: Imagem muito pequena recebida: %dx%d",
                    (int)image.size.width,
                    (int)image.size.height);
        }
    } @catch (NSException *exception) {
        writeLog(@"[FloatingWindow] Exceção ao atualizar imagem: %@", exception);
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.lastPosition = self.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        // Calcular nova posição
        CGPoint newCenter = CGPointMake(self.lastPosition.x + translation.x, self.lastPosition.y + translation.y);
        
        // Limites da tela para evitar que a janela saia da tela
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat minX = self.frame.size.width / 2;
        CGFloat maxX = screenBounds.size.width - minX;
        CGFloat minY = self.frame.size.height / 2;
        CGFloat maxY = screenBounds.size.height - minY;
        
        // Aplicar limites
        newCenter.x = MAX(minX, MIN(maxX, newCenter.x));
        newCenter.y = MAX(minY, MIN(maxY, newCenter.y));
        
        // Atualizar posição
        self.center = newCenter;
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        // Verificar se próximo a alguma borda e aderir (snap) a ela
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGPoint velocity = [gesture velocityInView:self];
        
        // Detecção de borda com base na velocidade
        if (fabs(velocity.x) > 500) {
            // Movimento rápido horizontal - aderir à borda esquerda ou direita
            if (velocity.x > 0) {
                // Mover para a direita
                [UIView animateWithDuration:0.3 animations:^{
                    self.center = CGPointMake(screenBounds.size.width - self.frame.size.width/2 - 10, self.center.y);
                }];
            } else {
                // Mover para a esquerda
                [UIView animateWithDuration:0.3 animations:^{
                    self.center = CGPointMake(self.frame.size.width/2 + 10, self.center.y);
                }];
            }
        }
    }
    
    [gesture setTranslation:CGPointZero inView:self];
}

// Método para adicionar duplo toque para minimizar/maximizar
- (void)addDoubleTapGesture {
    UITapGestureRecognizer *doubleTapGesture = [[UITapGestureRecognizer alloc]
                                               initWithTarget:self
                                               action:@selector(handleDoubleTap:)];
    doubleTapGesture.numberOfTapsRequired = 2;
    [self addGestureRecognizer:doubleTapGesture];
    
    // Certificar que o pan gesture não interfira com o double tap
    [self.panGesture requireGestureRecognizerToFail:doubleTapGesture];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    // Armazenar tamanho original e posição
    static CGRect originalFrame;
    static BOOL isMinimized = NO;
    
    if (isMinimized) {
        // Restaurar tamanho original
        [UIView animateWithDuration:0.3 animations:^{
            self.frame = originalFrame;
        }];
        isMinimized = NO;
    } else {
        // Minimizar para um canto
        originalFrame = self.frame;
        CGRect minimizedFrame = CGRectMake(
            self.superview.bounds.size.width - 80,
            40,
            70,
            70
        );
        
        [UIView animateWithDuration:0.3 animations:^{
            self.frame = minimizedFrame;
        }];
        isMinimized = YES;
    }
}

// Método para substituir a entrada da câmera quando WebRTC estiver funcionando
- (void)setupForCameraReplacement {
    // Este método será implementado quando o preview estiver funcionando corretamente
    // para preparar a conexão com AVCaptureSession e injetar o feed WebRTC
    writeLog(@"[FloatingWindow] Preparando para substituição da câmera");
    
    // Exemplo de como este método seria implementado:
    // 1. Obter o CMSampleBuffer atual do WebRTCManager
    CMSampleBufferRef sampleBuffer = [self.webRTCManager getLatestVideoSampleBuffer];
    
    if (sampleBuffer) {
        // 2. Injetar este buffer na AVCaptureSession
        writeLog(@"[FloatingWindow] SampleBuffer obtido com sucesso, pronto para injeção na AVCaptureSession");
        // O código real de injeção seria implementado no hook do AVCaptureSession
    } else {
        writeLog(@"[FloatingWindow] Não foi possível obter SampleBuffer válido");
    }
}

@end
