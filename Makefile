ARCHS = arm64
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WebRTCCamera

WebRTCCamera_FILES = Tweak.xm Logger.m WebRTCManager.m
WebRTCCamera_FRAMEWORKS = UIKit AVFoundation QuartzCore CoreImage CoreVideo CoreMedia
WebRTCCamera_LIBRARIES = substrate
WebRTCCamera_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -F./Frameworks -I./Frameworks/WebRTC.framework/Headers
WebRTCCamera_LDFLAGS = -F./Frameworks -framework WebRTC -Xlinker -rpath -Xlinker /Library/Frameworks

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks/WebRTC.framework
	cp -R ./Frameworks/WebRTC.framework/* $(THEOS_STAGING_DIR)/Library/Frameworks/WebRTC.framework/

after-install::
	install.exec "mkdir -p /Library/Frameworks/WebRTC.framework"
	install.exec "cp -R ./Frameworks/WebRTC.framework/* /Library/Frameworks/WebRTC.framework/"
	install.exec "ldid -S /Library/Frameworks/WebRTC.framework/WebRTC"
