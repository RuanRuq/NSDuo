#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
: "${NSDUO_TEAM_ID:?请设置 NSDUO_TEAM_ID 为自己的 Apple Developer Team ID}"
: "${NSDUO_BUNDLE_ID:?请设置 NSDUO_BUNDLE_ID 为自己的唯一 Bundle ID}"
: "${NSDUO_DEVICE_ID:?请设置 NSDUO_DEVICE_ID 为连接的 iPhone Duo 标识}"
cd "$NSDUO_ROOT"
# Repair the pinned JIT dependency before Xcode plans copy/sign operations.
python3 tools/nsduo/build-stikjit.py
# Xcode plans its incremental copy steps before executing the legacy core target.
# Publish first so planning sees the current dylib, rather than reusing an older
# embedded binary after a successful native build.
bash distribution/ios/build.sh
xcodebuild -project src/MeloNX/MeloNX.xcodeproj -scheme MeloNX \
  -configuration Debug -destination "id=$NSDUO_DEVICE_ID" \
  -derivedDataPath "$NSDUO_ROOT/.build/DerivedData" \
  -clonedSourcePackagesDirPath "$NSDUO_ROOT/.build/SourcePackages" \
  DEVELOPMENT_TEAM="$NSDUO_TEAM_ID" \
  NSDUO_BUNDLE_ID="${NSDUO_BUNDLE_ID}" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

# Code signing changes file bytes but preserves Mach-O UUIDs. Reject stale core
# packaging before an apparently successful build can be installed on a device.
python3 - "$NSDUO_ROOT" <<'PY'
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
core = root / "src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native/Ryujinx.Library.dylib"
embedded = root / ".build/DerivedData/Build/Products/Debug-iphoneos/MeloNX.app/Frameworks/Ryujinx.Library.dylib"

def uuids(path):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)
    result = set(re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output))
    if not result:
        raise SystemExit(f"无法验证模拟器核心：{path}")
    return result

if uuids(core) != uuids(embedded):
    raise SystemExit("打包失败：App 内的模拟器核心不是本次编译版本，请勿安装。")
print("已验证：App 内的模拟器核心与本次编译一致。")

jit = root / "src/MeloNX/Dependencies/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT"
embedded_jit = embedded.parent / "StikJIT.framework/StikJIT"
if uuids(jit) != uuids(embedded_jit):
    raise SystemExit("打包失败：App 未包含本次修正的 JIT 组件，请勿安装。")
import plistlib
metadata = plistlib.loads(embedded_jit.with_name("Info.plist").read_bytes())
if metadata.get("NSDuoJITAddressBits") != 64:
    raise SystemExit("打包失败：JIT 组件缺少完整地址修正标记。")
print("已验证：App 内的 JIT 组件与本次修正版本一致。")
PY
