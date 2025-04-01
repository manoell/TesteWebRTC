#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate, RTCVideoRenderer>

// Propriedades
@property (nonatomic, strong, readwrite) NSString *serverIP;
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;
@property (nonatomic, assign, readonly) BOOL active;

// Métodos
+ (instancetype)sharedInstance;
- (void)startWebRTC;
- (void)stopWebRTC;
- (CMSampleBufferRef)getLatestVideoSampleBuffer;
- (BOOL)isConnected;

@end
