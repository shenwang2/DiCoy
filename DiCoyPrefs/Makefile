TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DiCoyPrefs

DiCoyPrefs_FILES      = DiCoyPrefsListController.m
DiCoyPrefs_FRAMEWORKS = Foundation UIKit Preferences

DiCoyPrefs_CFLAGS     = -fobjc-arc

DiCoyPrefs_RESOURCE_DIRS = Resources

# --------------------------------------------------------------------------
# Rootless vs rootful install paths
# --------------------------------------------------------------------------
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  DiCoyPrefs_INSTALL_PATH = /var/jb/Library/PreferenceBundles
  _PREFLOADER_LAYOUT      = var/jb/Library/PreferenceLoader/Preferences
  JB_PREFIX               = /var/jb
else
  DiCoyPrefs_INSTALL_PATH = /Library/PreferenceBundles
  _PREFLOADER_LAYOUT      = Library/PreferenceLoader/Preferences
  JB_PREFIX               =
endif

# Stage the PreferenceLoader entry plist so it is included in the .deb.
before-package::
	mkdir -p $(THEOS_PROJECT_DIR)/layout/$(_PREFLOADER_LAYOUT)
	cp $(THEOS_PROJECT_DIR)/entry.plist \
	    $(THEOS_PROJECT_DIR)/layout/$(_PREFLOADER_LAYOUT)/DiCoy.plist

after-install::
	install.exec "mkdir -p $(JB_PREFIX)/Library/PreferenceLoader/Preferences"
	install.exec "cp $(THEOS_PROJECT_DIR)/entry.plist $(JB_PREFIX)/Library/PreferenceLoader/Preferences/DiCoy.plist"

include $(THEOS)/makefiles/bundle.mk
