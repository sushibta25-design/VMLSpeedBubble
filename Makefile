ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VMLSpeedBubble VMLRuntimeSniffer GoogleMapsPhoneSniffer GoogleMapsWeatherIPC CarPlayWeatherIPC CarPlayGoogleHostProbe CarPlayTemplateHostProbe WeatherSpeechBridge

VMLSpeedBubble_FILES = Tweak.xm
VMLSpeedBubble_CFLAGS = -fobjc-arc -Werror
VMLSpeedBubble_FRAMEWORKS = UIKit Foundation QuartzCore

VMLRuntimeSniffer_FILES = RuntimeSniffer.xm
VMLRuntimeSniffer_CFLAGS = -fobjc-arc -Werror
VMLRuntimeSniffer_FRAMEWORKS = UIKit Foundation
VMLRuntimeSniffer_LIBRARIES = substrate

GoogleMapsPhoneSniffer_FILES = GoogleMapsPhoneSniffer.xm
GoogleMapsPhoneSniffer_CFLAGS = -fobjc-arc -Werror
GoogleMapsPhoneSniffer_FRAMEWORKS = UIKit Foundation CoreLocation AVFoundation
GoogleMapsPhoneSniffer_LIBRARIES = substrate

GoogleMapsWeatherIPC_FILES = GoogleMapsWeatherIPC.xm
GoogleMapsWeatherIPC_CFLAGS = -fobjc-arc -Werror
GoogleMapsWeatherIPC_FRAMEWORKS = UIKit Foundation CoreLocation
GoogleMapsWeatherIPC_LIBRARIES = substrate

CarPlayWeatherIPC_FILES = CarPlayWeatherIPC.xm
CarPlayWeatherIPC_CFLAGS = -fobjc-arc -Werror
CarPlayWeatherIPC_FRAMEWORKS = UIKit Foundation QuartzCore
CarPlayWeatherIPC_LIBRARIES = substrate

CarPlayGoogleHostProbe_FILES = CarPlayGoogleHostProbe.xm
CarPlayGoogleHostProbe_CFLAGS = -fobjc-arc -Werror
CarPlayGoogleHostProbe_FRAMEWORKS = UIKit Foundation QuartzCore
CarPlayGoogleHostProbe_LIBRARIES = substrate

CarPlayTemplateHostProbe_FILES = CarPlayTemplateHostProbe.xm
CarPlayTemplateHostProbe_CFLAGS = -fobjc-arc -Werror
CarPlayTemplateHostProbe_FRAMEWORKS = UIKit Foundation QuartzCore CoreLocation
CarPlayTemplateHostProbe_LIBRARIES = substrate

WeatherSpeechBridge_FILES = WeatherSpeechBridge.xm
WeatherSpeechBridge_CFLAGS = -fobjc-arc -Werror
WeatherSpeechBridge_FRAMEWORKS = Foundation AVFoundation
WeatherSpeechBridge_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
