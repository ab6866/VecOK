# ===========================================================================
#  VecOK — Theos 工程
#  作者: 6866
#
#  关键：-Wl,-no_fixup_chains 必须加（官方规范点名的闪退/无效果头号原因）
#    不加时链接器会产出 __TEXT,__init_offsets（32 位相对偏移），
#    老式 Substrate / ElleKit 初始化扫描器只认 __DATA_CONST,__mod_init_func（指针），
#    结果就是 constructor 不执行（装上了没效果）或加载器误读（启动即闪退）。
# ===========================================================================

TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VecOK
VecOK_FILES = tw/Tweak.m
VecOK_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/generated -w
VecOK_LDFLAGS = -Wl,-no_fixup_chains

include $(THEOS_MAKE_PATH)/tweak.mk
