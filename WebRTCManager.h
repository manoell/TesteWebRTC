#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;
@class WebRTCFrameConverter;

@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>

@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, weak) FloatingWindow *floatingWindow;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) NSTimer *frameTimer;
@property (nonatomic, strong) WebRTCFrameConverter *frameConverter;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;
- (void)startWebRTC;
- (void)stopWebRTC;
- (void)captureAndSendTestImage;
- (CMSampleBufferRef)getLatestVideoSampleBuffer;
- (void)checkWebRTCStatus;
- (NSString *)iceConnectionStateToString:(RTCIceConnectionState)state;
- (NSString *)signalingStateToString:(RTCSignalingState)state;
- (void)connectWebSocket;
- (void)receiveMessage;
- (void)handleOfferWithSDP:(NSString *)sdp;

@end
