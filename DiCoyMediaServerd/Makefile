TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DiCoyMediaServerd

DiCoyMediaServerd_FILES = Tweak.x
DiCoyMediaServerd_CFLAGS = -fobjc-arc -DDICOY_ROOTLESS=1
DiCoyMediaServerd_FRAMEWORKS = CoreMedia CoreVideo AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk