ARCHS = arm64
TARGET := iphone:clang:latest:15
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CameraPreviewTweak

CameraPreviewTweak_FILES = Tweak.xm WebRTCCameraAdapter.m WebRTCManager.m WebRTCFrameConverter.m WebRTCBufferInjector.m logger.m PixelBufferLocker.m
CameraPreviewTweak_FRAMEWORKS = UIKit AVFoundation QuartzCore CoreImage CoreVideo CoreAudio AudioToolbox
CameraPreviewTweak_LIBRARIES = substrate
CameraPreviewTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations  -F./Frameworks -I./Frameworks/WebRTC.framework/Headers
CameraPreviewTweak_LDFLAGS = -F./Frameworks -framework WebRTC -Xlinker -rpath -Xlinker /Library/Frameworks

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks/WebRTC.framework
	cp -R ./Frameworks/WebRTC.framework/* $(THEOS_STAGING_DIR)/Library/Frameworks/WebRTC.framework/

after-install::
	install.exec "mkdir -p /Library/Frameworks/WebRTC.framework"
	install.exec "cp -R ./Frameworks/WebRTC.framework/* /Library/Frameworks/WebRTC.framework/"
	install.exec "ldid -S /Library/Frameworks/WebRTC.framework/WebRTC"
