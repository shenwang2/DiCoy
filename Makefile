export THEOS_PACKAGE_SCHEME = rootless
THEOS_BUILD_DIR = packages

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += DiCoyDaemon
SUBPROJECTS += DiCoyTweak
SUBPROJECTS += DiCoyPrefs

include $(THEOS)/makefiles/aggregate.mk
