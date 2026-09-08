ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VMLSpeedBubble

VMLSpeedBubble_FILES = Tweak.xm CarPlayLogger.xm RuntimeSniffer.xm
VMLSpeedBubble_CFLAGS = -fobjc-arc
VMLSpeedBubble_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
