TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DiCoyPrefs

DiCoyPrefs_FILES      = DiCoyPrefsListController.m
DiCoyPrefs_FRAMEWORKS         = Foundation UIKit
DiCoyPrefs_PRIVATE_FRAMEWORKS = Preferences

DiCoyPrefs_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/DiCoyTweak

DiCoyPrefs_RESOURCE_DIRS = Resources

# --------------------------------------------------------------------------
# Rootless vs rootful install paths
# --------------------------------------------------------------------------
# Theos rootless mode (THEOS_PACKAGE_SCHEME=rootless) auto-prepends /var/jb to
# all INSTALL_PATH values.  Do NOT include /var/jb here or the bundle lands at
# /var/jb/var/jb/Library/PreferenceBundles/ (double-prefix) and PreferenceLoader
# cannot find it.
DiCoyPrefs_INSTALL_PATH = /Library/PreferenceBundles

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  DiCoyPrefs_CFLAGS += -DDICOY_ROOTLESS=1
endif

include $(THEOS)/makefiles/bundle.mk
