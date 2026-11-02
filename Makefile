TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = Il2CppDumpDylib
Il2CppDumpDylib_FILES = src/Il2CppDumpDylib.xm
Il2CppDumpDylib_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
Il2CppDumpDylib_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/library.mk
