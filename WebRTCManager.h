#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;
@class WebRTCFrameConverter;

@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate>

@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, weak) FloatingWindow *floatingWindow;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) NSTimer *frameTimer;

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;
- (void)startWebRTC;
- (void)stopWebRTC;
- (void)captureAndSendTestImage;
- (CMSampleBufferRef)getLatestVideoSampleBuffer;

@end
