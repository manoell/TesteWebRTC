#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@class WebRTCManager;

@interface FloatingWindow : UIWindow

@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) WebRTCManager *webRTCManager;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;

- (instancetype)initWithFrame:(CGRect)frame;
- (void)show;
- (void)hide;
- (void)togglePreview:(UIButton *)sender;
- (void)updatePreviewImage:(UIImage *)image;
- (void)updateConnectionStatus:(NSString *)status;

@end
