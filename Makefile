export THEOS_PACKAGE_SCHEME = rootless
THEOS_BUILD_DIR = packages

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += DiCoyDaemon
SUBPROJECTS += DiCoyTweak
SUBPROJECTS += DiCoyMediaServerd
SUBPROJECTS += DiCoyPrefs

include $(THEOS)/makefiles/aggregate.mk

# -----------------------------------------------------------------------
# Stage supplementary files (PreferenceLoader entry, launchd plist) that
# are not handled by Theos's binary install machinery.
#
# internal-stage:: runs during the staging phase and writes directly into
# $(THEOS_STAGING_DIR), which is what dpkg-deb packages.
before-package::
# fires after layout/ has already been copied into staging, so any files
# written there at that point are too late — they never reach the deb.
# -----------------------------------------------------------------------
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  JB_PREFIX = /var/jb
else
  JB_PREFIX =
endif

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_PROJECT_DIR)/DiCoyPrefs/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DiCoy.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/LaunchDaemons$(ECHO_END)
	$(ECHO_NOTHING)sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' $(THEOS_PROJECT_DIR)/DiCoyDaemon/com.dicoy.daemon.plist.in > $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/LaunchDaemons/com.dicoy.daemon.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/libSandy$(ECHO_END)
	$(ECHO_NOTHING)sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' $(THEOS_PROJECT_DIR)/DiCoyTweak/libSandy.plist.in > $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/libSandy/DiCoy.plist$(ECHO_END)

# belt-and-suspenders: before-package:: also writes to $(THEOS_STAGING_DIR)
# in case internal-stage:: is not invoked for a pure aggregate root Makefile.
before-package::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_PROJECT_DIR)/DiCoyPrefs/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DiCoy.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/LaunchDaemons$(ECHO_END)
	$(ECHO_NOTHING)sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' $(THEOS_PROJECT_DIR)/DiCoyDaemon/com.dicoy.daemon.plist.in > $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/LaunchDaemons/com.dicoy.daemon.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/libSandy$(ECHO_END)
	$(ECHO_NOTHING)sed 's|%%JB_PREFIX%%|$(JB_PREFIX)|g' $(THEOS_PROJECT_DIR)/DiCoyTweak/libSandy.plist.in > $(THEOS_STAGING_DIR)$(JB_PREFIX)/Library/libSandy/DiCoy.plist$(ECHO_END)
