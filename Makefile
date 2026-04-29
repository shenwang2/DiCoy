export THEOS_PACKAGE_SCHEME = rootless
THEOS_BUILD_DIR = packages

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += DiCoyDaemon
SUBPROJECTS += DiCoyTweak
SUBPROJECTS += DiCoyPrefs

include $(THEOS)/makefiles/aggregate.mk

# -----------------------------------------------------------------------
# Rootless vs rootful layout paths.  These mirror the per-subproject
# variables so the root before-package:: works for both schemes.
# Subproject before-package:: hooks run only when building a subproject
# directly (make -C DiCoyPrefs); root-level make package only fires the
# hook defined here.
# -----------------------------------------------------------------------
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  JB_PREFIX             = /var/jb
  _PREFLOADER_LAYOUT    = var/jb/Library/PreferenceLoader/Preferences
  _LAUNCHDAEMONS_LAYOUT = var/jb/Library/LaunchDaemons
else
  JB_PREFIX             =
  _PREFLOADER_LAYOUT    = Library/PreferenceLoader/Preferences
  _LAUNCHDAEMONS_LAYOUT = Library/LaunchDaemons
endif

before-package::
	mkdir -p $(THEOS_PROJECT_DIR)/layout/$(_PREFLOADER_LAYOUT)
	cp $(THEOS_PROJECT_DIR)/DiCoyPrefs/entry.plist \
	    $(THEOS_PROJECT_DIR)/layout/$(_PREFLOADER_LAYOUT)/DiCoy.plist
	mkdir -p $(THEOS_PROJECT_DIR)/layout/$(_LAUNCHDAEMONS_LAYOUT)
	sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' \
	    $(THEOS_PROJECT_DIR)/DiCoyDaemon/com.dicoy.daemon.plist.in \
	    > $(THEOS_PROJECT_DIR)/layout/$(_LAUNCHDAEMONS_LAYOUT)/com.dicoy.daemon.plist
