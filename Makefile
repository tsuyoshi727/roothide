THEOS_PACKAGE_SCHEME ?= roothide
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
$(error This experimental project is intended for RootHide only)
endif
TARGET = iphone:clang:latest:15.0
FINALPACKAGE = 1
THEOS_LAYOUT_DIR_NAME = layout
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = Tinge18Standalone
Tinge18Standalone_FILES = Adaptive/Bridge.m Adaptive/Palette.c Adaptive/LayerSnapshot.m Adaptive/FolderSelection.m
Tinge18Standalone_CFLAGS = -fobjc-arc -fstack-protector-strong -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations
Tinge18Standalone_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics CoreFoundation
Tinge18Standalone_LIBRARIES = substrate roothide
include $(THEOS_MAKE_PATH)/tweak.mk
