export THEOS_PACKAGE_SCHEME = rootless
THEOS_BUILD_DIR = packages

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += DiCoyTweak
SUBPROJECTS += DiCoyPrefs

include $(THEOS)/makefiles/aggregate.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_PROJECT_DIR)/DiCoyPrefs/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DiCoy.plist$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst 2>/dev/null; true$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/prerm 2>/dev/null; true$(ECHO_END)
