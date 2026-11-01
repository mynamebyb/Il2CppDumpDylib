TARGET := iphone:clang:16.5:13.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = Il2CppDumpDylib
Il2CppDumpDylib_FILES = src/Il2CppDumpDylib.xm
Il2CppDumpDylib_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
Il2CppDumpDylib_FRAMEWORKS = Foundation UIKit
Il2CppDumpDylib_LDFLAGS = -Wl,-no_uuid

include $(THEOS_MAKE_PATH)/library.mk
