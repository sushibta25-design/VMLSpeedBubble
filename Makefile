ARCHS = arm64 arm64e
TARGET = iphone:clang:16.4:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VMLSpeedBubble

VMLSpeedBubble_FILES = Tweak.xm
VMLSpeedBubble_CFLAGS = -fobjc-arc
VMLSpeedBubble_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
