#!/usr/bin/env bash
# setup_theos.sh <rootless|roothide>
# 安装对应方案的 Theos（两个方案必须用不同的 Theos，不可混用）
set -euo pipefail
SCHEME="${1:-rootless}"

if [ "$SCHEME" = "roothide" ]; then
  THEOS_DIR="$HOME/theos-rh"
  git clone --recursive --depth 1 https://github.com/roothide/theos.git "$THEOS_DIR"
else
  THEOS_DIR="$HOME/theos"
  git clone --recursive --depth 1 https://github.com/theos/theos.git "$THEOS_DIR"
fi

# SDK（若无则下载 iPhoneOS SDK）
if [ ! -d "$THEOS_DIR/sdks" ] || [ -z "$(ls -A "$THEOS_DIR/sdks" 2>/dev/null)" ]; then
  echo "downloading SDK..."
  git clone --depth 1 https://github.com/theos/sdks.git /tmp/theos-sdks
  mkdir -p "$THEOS_DIR/sdks"
  cp /tmp/theos-sdks/*.sdk.tar* "$THEOS_DIR/sdks/" 2>/dev/null || true
  for f in /tmp/theos-sdks/*.sdk; do
    [ -d "$f" ] && cp -R "$f" "$THEOS_DIR/sdks/"
  done
fi

echo "THEOS_DIR=$THEOS_DIR" >> "$GITHUB_ENV"
echo "THEOS=$THEOS_DIR" >> "$GITHUB_ENV"
echo "theos ready at $THEOS_DIR"
ls "$THEOS_DIR/sdks" | head
