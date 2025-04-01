#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate, RTCVideoRenderer>

// Flag que indica se está recebendo frames
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

// Inicializa o manager com um IP de servidor
- (instancetype)initWithServerIP:(NSString *)serverIP;

// Inicia a conexão WebRTC
- (void)startWebRTC;

// Encerra a conexão WebRTC
- (void)stopWebRTC;

// Obtém o último frame como CMSampleBuffer para display
- (CMSampleBufferRef)getLatestVideoSampleBuffer;

@end
