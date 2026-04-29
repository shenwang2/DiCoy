export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:15.0
THEOS_BUILD_DIR = packages

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += DiCoyDaemon
SUBPROJECTS += DiCoyTweak
SUBPROJECTS += DiCoyPrefs

include $(THEOS)/makefiles/aggregate.mk