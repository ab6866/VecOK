#!/usr/bin/env bash
# build.sh <rootless|roothide>
# 用对应方案的 Theos 构建包，并按 scheme 组装 payload + control。
set -euo pipefail
SCHEME="${1:-rootless}"

# 先生成（注入 Secrets），再载入其导出的包名
python3 ci/gen.py
set -a; . ci/build.env; set +a

if [ "$SCHEME" = "roothide" ]; then
  export THEOS="$HOME/theos-rh"
  export THEOS_PACKAGE_SCHEME=roothide
else
  export THEOS="$HOME/theos"
  export THEOS_PACKAGE_SCHEME=rootless
fi

# Theos 的 tweak.mk 在 stage 阶段要求工程根目录存在 <TWEAK_NAME>.plist
if [ -n "${FILTER_NAME:-}" ] && [ -f "dsc/${FILTER_NAME}.plist" ]; then
  cp "dsc/${FILTER_NAME}.plist" "${TWEAK_NAME}.plist"
fi

# 切换 control（双包规范）
cp "dsc/control.$SCHEME" dsc/control
# Theos 的 make package 需要工程根目录或 layout/DEBIAN 下存在 control
cp "dsc/control.$SCHEME" control

make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

DEB=$(ls -t packages/*.deb | head -1)
echo "built: $DEB"

# 取出 dylib 并自行组装（保证 payload 根与 control 精确可控）
rm -rf /tmp/okpkg
mkdir -p /tmp/okpkg
dpkg-deb -x "$DEB" /tmp/okpkg
DYLIB=$(find /tmp/okpkg -name '*.dylib' | head -1)
echo "dylib: $DYLIB"

if [ -z "$DYLIB" ]; then
  echo "!! 未找到 dylib，构建失败"
  exit 1
fi

OUT="packages/out-${SCHEME}"
rm -rf "$OUT"
if [ "$SCHEME" = "roothide" ]; then
  DEST="$OUT/Library/MobileSubstrate/DynamicLibraries"
else
  DEST="$OUT/var/jb/Library/MobileSubstrate/DynamicLibraries"
fi
mkdir -p "$DEST" "$OUT/DEBIAN"
cp "$DYLIB" "$DEST/${TWEAK_NAME}.dylib"
chmod 755 "$DEST/${TWEAK_NAME}.dylib"
cp "dsc/${FILTER_NAME}.plist" "$DEST/${TWEAK_NAME}.plist"
cp "dsc/control.$SCHEME" "$OUT/DEBIAN/control"

# 压缩用 gzip（部分越狱 dpkg 不带 xz 解码器）
dpkg-deb -Zgzip -b --root-owner-group "$OUT" "packages/${DISPLAY_ASCII}-${SCHEME}.deb"

echo "=== 产物验收 ==="
F="packages/${DISPLAY_ASCII}-${SCHEME}.deb"
dpkg-deb -I "$F" | grep -E '^ (Package|Version|Architecture|Depends|Conflicts|Replaces)'
dpkg-deb -c "$F"
echo "--- dylib 静态检查"
echo "slices : $(llvm-lipo -info "$DEST/${TWEAK_NAME}.dylib" 2>/dev/null || lipo -info "$DEST/${TWEAK_NAME}.dylib")"
echo "mod_init : $(otool -l "$DEST/${TWEAK_NAME}.dylib" | grep -c __mod_init_func)"
echo "init_offsets : $(otool -l "$DEST/${TWEAK_NAME}.dylib" | grep -c __init_offsets)"
echo "install_name : $(otool -D "$DEST/${TWEAK_NAME}.dylib" | tail -1)"
