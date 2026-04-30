TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DiCoyTweak

DiCoyTweak_FILES      = Tweak.x DiCoyClient.m
DiCoyTweak_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo IOSurface \
                        QuartzCore CoreFoundation AudioToolbox CoreImage
DiCoyTweak_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
DiCoyTweak_CFLAGS    += -DDICOY_ROOTLESS=1
endif

include $(THEOS)/makefiles/tweak.mk
