#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
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
        self.backgroundColor = [UIColor redColor];
        self.layer.cornerRadius = 10;
        self.clipsToBounds = YES;
        
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
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, self.bounds.size.width - 20, 25)];
        self.statusLabel.text = @"WebRTC";
        self.statusLabel.textColor = [UIColor whiteColor];
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        self.statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        self.statusLabel.layer.cornerRadius = 5;
        self.statusLabel.clipsToBounds = YES;
        [self.contentView addSubview:self.statusLabel];
        
        // Botão de controle
        self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.toggleButton.frame = CGRectMake(0, self.bounds.size.height - 50, self.bounds.size.width, 50);
        [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:self.toggleButton];
        
        // Gesture recognizer para mover
        self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:self.panGesture];
        
        // Inicializar WebRTC manager
        self.webRTCManager = [[WebRTCManager alloc] initWithFloatingWindow:self];
        
        self.isPreviewActive = NO;
    }
    return self;
}

- (void)show {
    self.hidden = NO;
    [self makeKeyAndVisible];
}

- (void)hide {
    [self stopPreview];
    self.hidden = YES;
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
    [self.webRTCManager startWebRTC];
}

- (void)stopPreview {
    self.statusLabel.text = @"Desconectado";
    [self.webRTCManager stopWebRTC];
    self.previewImageView.image = nil;
}

- (void)updatePreviewImage:(UIImage *)image {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.previewImageView.image = image;
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.lastPosition = self.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.lastPosition.x + translation.x, self.lastPosition.y + translation.y);
    }
    
    [gesture setTranslation:CGPointZero inView:self];
}

@end
