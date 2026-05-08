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
# Theos rootless mode auto-prepends /var/jb to INSTALL_PATH.  Use the bare
# path so the binary lands at /var/jb/usr/sbin/ without double-prefix.
DiCoyDaemon_INSTALL_PATH = /usr/sbin

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  JB_PREFIX           = /var/jb
  DiCoyDaemon_CFLAGS += -DDICOY_ROOTLESS=1
else
  JB_PREFIX           =
endif

# Re-load the daemon on the device after SSH install.
after-install::
	install.exec "launchctl unload $(JB_PREFIX)/Library/LaunchDaemons/com.dicoy.daemon.plist 2>/dev/null; true"
	install.exec "launchctl load  $(JB_PREFIX)/Library/LaunchDaemons/com.dicoy.daemon.plist"

include $(THEOS)/makefiles/tool.mk
