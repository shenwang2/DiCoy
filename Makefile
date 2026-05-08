export THEOS_PACKAGE_SCHEME = rootless
THEOS_BUILD_DIR = packages

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += DiCoyDaemon
SUBPROJECTS += DiCoyTweak
SUBPROJECTS += DiCoyPrefs

include $(THEOS)/makefiles/aggregate.mk

before-package::
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst 2>/dev/null; true$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/prerm 2>/dev/null; true$(ECHO_END)
