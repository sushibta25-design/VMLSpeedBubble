ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VMLSpeedBubble VMLRuntimeSniffer GoogleMapsPhoneSniffer

VMLSpeedBubble_FILES = Tweak.xm
VMLSpeedBubble_CFLAGS = -fobjc-arc -Werror
VMLSpeedBubble_FRAMEWORKS = UIKit Foundation QuartzCore

VMLRuntimeSniffer_FILES = RuntimeSniffer.xm
VMLRuntimeSniffer_CFLAGS = -fobjc-arc -Werror
VMLRuntimeSniffer_FRAMEWORKS = UIKit Foundation
VMLRuntimeSniffer_LIBRARIES = substrate

GoogleMapsPhoneSniffer_FILES = GoogleMapsPhoneSniffer.xm
GoogleMapsPhoneSniffer_CFLAGS = -fobjc-arc -Werror
GoogleMapsPhoneSniffer_FRAMEWORKS = UIKit Foundation
GoogleMapsPhoneSniffer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
