#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>

@interface WebRTCFrameConverter : NSObject <RTCVideoRenderer>

@property (nonatomic, copy) void (^frameCallback)(UIImage *image);

- (instancetype)init;
- (void)setRenderFrame:(RTCVideoFrame *)frame;

@end
