TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DiCoyTweak

DiCoyTweak_FILES      = Tweak.x DiCoyClient.m
DiCoyTweak_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo IOSurface \
                        QuartzCore CoreFoundation AudioToolbox CoreImage
DiCoyTweak_LIBRARIES  = sandy
DiCoyTweak_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  DiCoyTweak_CFLAGS  += -DDICOY_ROOTLESS=1
  JB_PREFIX           = /var/jb
  _SANDY_LAYOUT       = var/jb/Library/libSandy
else
  JB_PREFIX           =
  _SANDY_LAYOUT       = Library/libSandy
endif

# Deploy the Sandy sandbox-extension profile so libSandy_applyProfile("DiCoy")
# succeeds at runtime.  sandyd looks for profiles at JBROOT/Library/libSandy/<name>.plist
# and rejects files not owned by root:root, which dpkg satisfies automatically.
before-package::
	mkdir -p $(THEOS_PROJECT_DIR)/layout/$(_SANDY_LAYOUT)
	sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' \
	    $(THEOS_PROJECT_DIR)/libSandy.plist.in \
	    > $(THEOS_PROJECT_DIR)/layout/$(_SANDY_LAYOUT)/DiCoy.plist

include $(THEOS)/makefiles/tweak.mk
