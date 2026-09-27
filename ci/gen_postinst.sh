#!/usr/bin/env bash
# gen_postinst.sh <rootless|roothide>
# 由 CI 生成 DEBIAN/postinst 与 postrm：
#   1) 安装时结束目标 App 进程（用户明确要求：装/卸都要杀进程）
#   2) 在设备上静态改写目标 App 主二进制（与已验证有效的注入版同一套补丁）
#   3) ★ 改写后立即用原 entitlements 重签 —— 否则 amfid 校验失败 → 启动闪退
#
# 所有目标相关信息（App 名、bundle id、补丁表、entitlements）都来自
# ci/gen.py 生成的 generated/ 目录（构建期由 Secrets 注入），仓库内不含真实标识。
set -euo pipefail
SCHEME="${1:-rootless}"

set -a; . ci/build.env; set +a
export OK_PATCHES="${OK_PATCHES:-}"

APPNAME="${OK_APP_NAME:?OK_APP_NAME missing}"
BINNAME="${OK_BIN_NAME:?OK_BIN_NAME missing}"
BUNDLE="${OK_BUNDLE_ID:?OK_BUNDLE_ID missing}"
ENTFILE="${OK_ENTITLEMENTS_FILE:?OK_ENTITLEMENTS_FILE missing}"

OUT="dsc/postinst.${SCHEME}"
OUTRM="dsc/postrm.${SCHEME}"

# ------------------------------------------------------------------ postinst
cat > "$OUT" <<'HEADER'
#!/bin/sh
# 安装即生效：结束进程 → 静态改写目标二进制 → 重签 → 再次结束进程
# 任何情况 exit 0，绝不阻断 dpkg。
LOG=/tmp/vecok.postinst.log
echo "=== VecOK postinst ===" >> $LOG
log() { echo "$1" >> $LOG; }
HEADER

cat >> "$OUT" <<CONF
APPNAME="$APPNAME"
BINNAME="$BINNAME"
CONF

cat >> "$OUT" <<'BODY'

find_tool() { for c in "$@"; do [ -x "$c" ] && { echo "$c"; return 0; }; done; return 1; }
LAUNCHCTL=$(find_tool /var/jb/bin/launchctl /var/jb/usr/bin/launchctl /bin/launchctl /usr/bin/launchctl)
KILLALL=$(find_tool /var/jb/usr/bin/killall /var/jb/bin/killall /usr/bin/killall /bin/killall)
LDID=$(find_tool /var/jb/usr/bin/ldid /var/jb/usr/local/bin/ldid /usr/bin/ldid /usr/local/bin/ldid)
log "launchctl=${LAUNCHCTL:-none} killall=${KILLALL:-none} ldid=${LDID:-none}"

find_bin() {
  for base in /var/containers/Bundle/Application \
              /private/var/containers/Bundle/Application; do
    [ -d "$base" ] || continue
    for d in "$base"/*/; do
      [ -f "$d$APPNAME.app/$BINNAME" ] && { echo "$d$APPNAME.app/$BINNAME"; return 0; }
    done
  done
  return 1
}

proc_alive() {
  for p in /proc/[0-9]*; do
    [ -d "$p" ] || continue
    [ "$(cat $p/comm 2>/dev/null)" = "$BINNAME" ] && return 0
  done
  return 1
}

kill_app() {
  log "--- 结束 App 进程"
  [ -n "$LAUNCHCTL" ] && "$LAUNCHCTL" killall "$BINNAME" >> $LOG 2>&1
  proc_alive && [ -n "$KILLALL" ] && "$KILLALL" -9 "$BINNAME" >> $LOG 2>&1
  if proc_alive; then
    for p in /proc/[0-9]*; do
      [ -d "$p" ] || continue
      if [ "$(cat $p/comm 2>/dev/null)" = "$BINNAME" ]; then
        kill -9 "$(basename "$p")" 2>/dev/null
      fi
    done
  fi
  n=0
  while [ $n -lt 30 ]; do
    proc_alive || { log "App 已退出"; return 0; }
    i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done
    n=$((n+1))
  done
  log "!! App 仍在运行"
  return 1
}

# 无论能否改二进制，先把进程结束掉（用户要求）
kill_app

BIN=$(find_bin)
if [ -z "$BIN" ]; then
  log "!! 未找到目标二进制（$APPNAME.app/$BINNAME）；请确保 App 已安装后重装本包"
  exit 0
fi
log "目标: $BIN"

patch() {
  off=$1; want=$2; newhex=$3; newesc=$4
  got=$(od -An -tx1 -j "$off" -N 4 "$BIN" 2>/dev/null | tr -d ' \n')
  [ "$got" = "$newhex" ] && { log "  [跳过] $off 已是目标值"; return 0; }
  [ "$got" != "$want" ] && { log "  [!!] $off 原字节不符 期望=$want 实际=$got"; return 1; }
  printf "$newesc" > /tmp/.ok_pb.bin
  dd if=/tmp/.ok_pb.bin of="$BIN" bs=1 seek="$off" conv=notrunc >> $LOG 2>&1
  rm -f /tmp/.ok_pb.bin
  back=$(od -An -tx1 -j "$off" -N 4 "$BIN" 2>/dev/null | tr -d ' \n')
  [ "$back" = "$newhex" ] && { log "  [OK] $off $want -> $newhex"; return 0; }
  log "  [!!] $off 回读不符 = $back"; return 1
}

BAK="${BIN}.vecok.bak"
[ -f "$BAK" ] || { cp "$BIN" "$BAK" 2>/dev/null && log "已备份原始二进制"; }

log "--- 写入补丁"
OK=0
BODY

# 追加补丁调用（来自构建期注入）
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
patches = json.loads(os.environ.get("OK_PATCHES", "[]"))
if not patches:
    print("!! OK_PATCHES 为空", file=sys.stderr); raise SystemExit(1)
with open(out, "a") as f:
    for p in patches:
        f.write("patch %s %s %s '%s' && OK=$((OK+1))\n" % (
            p["off"], p["want"], p["got"], p["esc"]))
    f.write("log \"applied = $OK / %d\"\n" % len(patches))
PY

cat >> "$OUT" <<'TAIL'
chmod 755 "$BIN" 2>/dev/null

if [ "$OK" -gt 0 ]; then
  ENT=/tmp/.ok_app.ent
  cat > "$ENT" <<'ENTEOF'
__ENTITLEMENTS__
ENTEOF
  if [ -n "$LDID" ]; then
    if "$LDID" -S"$ENT" "$BIN" >> $LOG 2>&1; then
      log "★ 已用 entitlements 重签（$LDID）"
    else
      "$LDID" -S "$BIN" >> $LOG 2>&1 && log "已 ad-hoc 重签" || log "!! 重签失败"
    fi
  else
    log "!! 未找到 ldid → 改字节后签名失效会导致启动闪退，现恢复备份"
    [ -f "$BAK" ] && cp "$BAK" "$BIN" 2>/dev/null && chmod 755 "$BIN" 2>/dev/null && log "已恢复原始二进制"
  fi
  rm -f "$ENT" 2>/dev/null
fi

# 改完再停一次，确保只有冷启动加载新代码
proc_alive && kill_app
log "=== postinst 结束 applied=$OK ==="
exit 0
TAIL

# 注入 entitlements（构建期来自 secret）
python3 - "$OUT" "$ENTFILE" <<'PY'
import sys
out, entf = sys.argv[1], sys.argv[2]
s = open(out).read()
ent = open(entf).read().strip()
s = s.replace("__ENTITLEMENTS__", ent)
open(out, "w").write(s)
print("entitlements embedded:", len(ent), "bytes")
PY

# ------------------------------------------------------------------ postrm
cat > "$OUTRM" <<HEADER
#!/bin/sh
# 卸载时结束进程并还原原始二进制，避免残留
trap 'exit 0' EXIT
LOG=/tmp/vecok.postrm.log
echo "=== VecOK postrm ===" >> \$LOG
log() { echo "\$1" >> \$LOG; }
BINNAME="$BINNAME"
APPNAME="$APPNAME"
HEADER

cat >> "$OUTRM" <<'BODY'
find_bin() {
  for base in /var/containers/Bundle/Application \
              /private/var/containers/Bundle/Application; do
    [ -d "$base" ] || continue
    for d in "$base"/*/; do
      [ -f "$d$APPNAME.app/$BINNAME" ] && { echo "$d$APPNAME.app/$BINNAME"; return 0; }
    done
  done
  return 1
}

for c in /var/jb/bin/launchctl /var/jb/usr/bin/launchctl /bin/launchctl /usr/bin/launchctl; do
  [ -x "$c" ] && { "$c" killall "$BINNAME" >> $LOG 2>&1; break; }
done
for c in /var/jb/usr/bin/killall /var/jb/bin/killall /usr/bin/killall /bin/killall; do
  [ -x "$c" ] && { "$c" -9 "$BINNAME" >> $LOG 2>&1; break; }
done

BIN=$(find_bin)
if [ -n "$BIN" ]; then
  BAK="${BIN}.vecok.bak"
  if [ -f "$BAK" ]; then
    cp "$BAK" "$BIN" 2>/dev/null && chmod 755 "$BIN" 2>/dev/null
    log "已从备份还原目标二进制"
    rm -f "$BAK" 2>/dev/null
  else
    log "无备份（安装时可能未定位到 App）"
  fi
else
  log "未找到目标二进制，无需还原"
fi
log "=== postrm 结束 ==="
exit 0
BODY

chmod 755 "$OUT" "$OUTRM"
sh -n "$OUT" && sh -n "$OUTRM"
echo "生成: $OUT ($(wc -c < "$OUT") B)  $OUTRM ($(wc -c < "$OUTRM") B)"
