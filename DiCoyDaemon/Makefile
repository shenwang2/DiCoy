TARGET  := iphone:clang:latest:15.0
ARCHS   := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = DiCoyDaemon

DiCoyDaemon_FILES      = main.m
DiCoyDaemon_FRAMEWORKS = Foundation IOSurface CoreGraphics CoreFoundation UIKit
DiCoyDaemon_LDFLAGS    = -framework IOKit
DiCoyDaemon_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR) -Wno-deprecated-declarations

DiCoyDaemon_CODESIGN_FLAGS = -Sentitlements.plist

# --------------------------------------------------------------------------
# Rootless vs rootful path selection.
# THEOS_PACKAGE_SCHEME is exported by the root Makefile; command-line
# overrides (THEOS_PACKAGE_SCHEME=) override it for rootful builds.
# --------------------------------------------------------------------------
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  JB_PREFIX              = /var/jb
  _LAUNCHDAEMONS_LAYOUT  = var/jb/Library/LaunchDaemons
  DiCoyDaemon_INSTALL_PATH = /var/jb/usr/sbin
  DiCoyDaemon_CFLAGS    += -DDICOY_ROOTLESS=1
else
  JB_PREFIX              =
  _LAUNCHDAEMONS_LAYOUT  = Library/LaunchDaemons
  DiCoyDaemon_INSTALL_PATH = /usr/sbin
endif

# --------------------------------------------------------------------------
# Generate com.dicoy.daemon.plist from the .in template before packaging
# so the binary path inside the plist matches the actual install prefix.
# The generated file is staged into layout/ which Theos includes in the .deb.
# --------------------------------------------------------------------------
before-package::
	mkdir -p $(THEOS_PROJECT_DIR)/layout/$(_LAUNCHDAEMONS_LAYOUT)
	sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' \
	    $(THEOS_PROJECT_DIR)/com.dicoy.daemon.plist.in \
	    > $(THEOS_PROJECT_DIR)/layout/$(_LAUNCHDAEMONS_LAYOUT)/com.dicoy.daemon.plist

# Re-load the daemon on the device after SSH install.
after-install::
	install.exec "launchctl unload $(JB_PREFIX)/Library/LaunchDaemons/com.dicoy.daemon.plist 2>/dev/null; true"
	install.exec "launchctl load  $(JB_PREFIX)/Library/LaunchDaemons/com.dicoy.daemon.plist"

include $(THEOS)/makefiles/tool.mk
