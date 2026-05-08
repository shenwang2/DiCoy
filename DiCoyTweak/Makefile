TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DiCoyTweak

DiCoyTweak_FILES      = Tweak.x DiCoyClient.m DiCoyServer.m
DiCoyTweak_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo IOSurface \
                        QuartzCore CoreFoundation AudioToolbox CoreImage
DiCoyTweak_LIBRARIES  = sandy
DiCoyTweak_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  DiCoyTweak_CFLAGS  += -DDICOY_ROOTLESS=1
  JB_PREFIX           = /var/jb
else
  JB_PREFIX           =
endif

# Deploy the Sandy sandbox-extension profile so libSandy_applyProfile("DiCoy")
# succeeds at runtime.  sandyd looks for profiles at JBROOT/Library/libSandy/<name>.plist
# and rejects files not owned by root:root, which dpkg satisfies automatically.
# THEOS_STAGING_DIR is rooted at the jailbreak prefix for rootless builds,
# so write bare Library/ paths — never add $(JB_PREFIX) to staging paths.
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/libSandy$(ECHO_END)
	$(ECHO_NOTHING)sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' \
	    $(THEOS_PROJECT_DIR)/DiCoyTweak/libSandy.plist.in \
	    > $(THEOS_STAGING_DIR)/Library/libSandy/DiCoy.plist$(ECHO_END)

include $(THEOS)/makefiles/tweak.mk
