#!/usr/bin/env python3
"""
gen.py — 构建期将 Secrets 注入为源码头文件（公开仓库内零敏感信息）

读取环境变量，生成 generated/ok_conf.h 与 dsc/<filter>.plist。
仓库里只有本脚本与占位模板，真实 App 标识、偏好键、产品 ID、包名等全部来自
GitHub Actions Secrets，不落盘到版本库。
"""
import os, plistlib, sys, pathlib

def env(name, default=""):
    v = os.environ.get(name, default)
    return v.strip()

# ---- 从 Secrets 读取（公开仓库内不出现任何目标 App 信息）
TARGET_CLASS = env("OK_TARGET_CLASS", "OkStore")
PRO_KEY      = env("OK_PRO_KEY", "")
KC_SERVICE   = env("OK_KC_SERVICE", "")
KC_ACCOUNT   = env("OK_KC_ACCOUNT", "")
APP_GROUP    = env("OK_APP_GROUP", "")

PKG_ROOTLESS = env("OK_PKG_ROOTLESS", "")
PKG_ROOTHIDE = env("OK_PKG_ROOTHIDE", "")
BUNDLES      = [b.strip() for b in env("OK_BUNDLES", "").split(",") if b.strip()]
DISPLAY_ASCII = env("OK_DISPLAY_ASCII", "app")
DISPLAY_NAME  = env("OK_DISPLAY_NAME", "")     # 显示名，仅进 Release 文件名，不进仓库
DESC          = env("OK_DESC", "Tweak build") # 包描述，来自 secret
FILTER_NAME   = env("OK_FILTER_NAME", "VecOK")

# ---- 包名兜底（若未提供，从环境派生，仍不落任何真实 App 标识）
if not PKG_ROOTLESS:
    PKG_ROOTLESS = "com.6866.vecok.rootless"
if not PKG_ROOTHIDE:
    PKG_ROOTHOIDE = "com.6866.vecok.roothide"
else:
    PKG_ROOTHOIDE = PKG_ROOTHIDE

if not BUNDLES:
    print("!! OK_BUNDLES 未设置，filter 将为空（无法注入）", file=sys.stderr)
    sys.exit(1)

# ---- 生成 C 头文件
root = pathlib.Path(__file__).resolve().parent.parent
gen = root / "generated"
gen.mkdir(exist_ok=True)

def cstr(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

h = f"""// 本文件由 ci/gen.py 在构建期生成，不在版本库内。
#ifndef OK_CONF_H
#define OK_CONF_H

#define OK_TARGET_CLASS {cstr(TARGET_CLASS)}
#define OK_PRO_KEY      {cstr(PRO_KEY)}
#define OK_KC_SERVICE   {cstr(KC_SERVICE)}
#define OK_KC_ACCOUNT   {cstr(KC_ACCOUNT)}
#define OK_APP_GROUP    {cstr(APP_GROUP)}

#endif
"""
(gen / "ok_conf.h").write_text(h)
print(f"generated/ok_conf.h  ({len(h)} bytes)")

# ---- 生成注入 plist（顶层必须是 Filter -> Bundles）
dsc = root / "dsc"
dsc.mkdir(exist_ok=True)
plist = {"Filter": {"Bundles": BUNDLES}}
with open(dsc / f"{FILTER_NAME}.plist", "wb") as f:
    plistlib.dump(plist, f)
print(f"dsc/{FILTER_NAME}.plist  bundles={BUNDLES}")

# ---- 生成双包 control
def control(pkg, arch, name_suffix, conflicts):
    return f"""Package: {pkg}
Name: {DISPLAY_NAME or 'App OK'} ({name_suffix})
Version: 1.0.0
Architecture: {arch}
Maintainer: 6866
Author: 6866
Section: Tweaks
Depends: firmware (>= 14.0)
Conflicts: {conflicts}
Replaces: {conflicts}
Description: {DESC}
 作者 6866
"""

(dsc / "control.rootless").write_text(
    control(PKG_ROOTLESS, "iphoneos-arm64", "Rootless", PKG_ROOTHOIDE))
(dsc / "control.roothide").write_text(
    control(PKG_ROOTHOIDE, "iphoneos-arm64e", "RootHide", PKG_ROOTLESS))
print("dsc/control.rootless, dsc/control.roothide")

# ---- 导出给后续脚本使用
with open(root / "ci" / "build.env", "w") as f:
    f.write(f"PKG_ROOTLESS={PKG_ROOTLESS}\n")
    f.write(f"PKG_ROOTHIDE={PKG_ROOTHOIDE}\n")
    f.write(f"FILTER_NAME={FILTER_NAME}\n")
    f.write("TWEAK_NAME=VecOK\n")
    f.write(f"DISPLAY_ASCII={DISPLAY_ASCII}\n")
print("ci/build.env")
