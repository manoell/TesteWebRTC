#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@interface WebRTCFrameConverter : NSObject <RTCVideoRenderer>

@property (nonatomic, copy) void (^frameCallback)(UIImage *image);
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

- (instancetype)init;
- (void)setRenderFrame:(RTCVideoFrame *)frame;
- (CMSampleBufferRef)getLatestSampleBuffer;

@end
