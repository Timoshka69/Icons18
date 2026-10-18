ARCHS = arm64
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

# make package ROOTLESS=1  -> пакет для rootless-джейла (palera1n -l, Dopamine)
ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME = rootless
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Icons18

Icons18_FILES = Tweak.x
Icons18_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Icons18_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
