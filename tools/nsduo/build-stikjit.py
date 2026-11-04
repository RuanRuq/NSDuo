#!/usr/bin/env python3
"""Rebuild pinned StikJIT with NS Duo's address fix and first-pairing adapter.

All inputs are local. Called before Xcode plans its framework copy/sign steps.
No global packages, network downloads, simulator builds or signing are needed.
"""
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LEGAL = ROOT / "distribution/legal/StikJIT"
PATCHES = ROOT / "tools/nsduo/stikjit"
BUILD = ROOT / ".build/StikJIT"
DEST = ROOT / "src/MeloNX/Dependencies/StikJIT.xcframework/ios-arm64/StikJIT.framework"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    with (BUILD / "build.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        archive = LEGAL / "StikJIT-1.9.0-source.tar.gz"
        provenance = json.loads((LEGAL / "provenance.json").read_text())
        if digest(archive) != provenance["sourceArchiveSHA256"]:
            raise SystemExit("StikJIT 固定版本源码校验失败。")
        sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path")
        compiler = run("xcrun", "--find", "swiftc")
        inputs = [archive, Path(__file__), *sorted(PATCHES.glob("*.swift"))]
        signature = hashlib.sha256((sdk + run(compiler, "--version") +
                                    "".join(digest(p) for p in inputs)).encode()).hexdigest()
        stamp_path = BUILD / "build.json"
        if stamp_path.exists() and (DEST / "StikJIT").exists():
            stamp = json.loads(stamp_path.read_text())
            metadata = plistlib.loads((DEST / "Info.plist").read_bytes())
            if (stamp.get("inputs") == signature and
                    stamp.get("binary") == digest(DEST / "StikJIT") and
                    metadata.get("NSDuoJITAddressBits") == 64 and
                    metadata.get("NSDuoOnDevicePairing") == 2):
                print("StikJIT 地址修复与本机配对组件已就绪。")
                return

        source = BUILD / "source"
        source.mkdir(exist_ok=True)
        subprocess.run(["tar", "-xzf", str(archive), "--strip-components=1",
                        "-C", str(source)], check=True)
        for path in PATCHES.glob("*.swift"):
            shutil.copy2(path, source / "Sources" / path.name)

        framework = BUILD / "StikJIT.framework"
        if framework.exists():
            shutil.rmtree(framework)
        modules = framework / "Modules/StikJIT.swiftmodule"
        modules.mkdir(parents=True)
        metadata = plistlib.loads((DEST / "Info.plist").read_bytes())
        metadata["NSDuoJITAddressBits"] = 64
        metadata["NSDuoOnDevicePairing"] = 2
        (framework / "Info.plist").write_bytes(plistlib.dumps(metadata))
        for resource in (source / "Resources").iterdir():
            if resource.is_file():
                shutil.copy2(resource, framework / resource.name)
        command = [compiler, "-sdk", sdk, "-target", "arm64-apple-ios17.4",
                   "-swift-version", "5", "-O", "-g", "-parse-as-library",
                   "-enable-library-evolution", "-module-name", "StikJIT",
                   "-module-cache-path", str(BUILD / "ModuleCache"),
                   "-emit-library", "-emit-module",
                   "-emit-module-path", str(modules / "arm64-apple-ios.swiftmodule"),
                   "-emit-module-interface-path", str(modules / "arm64-apple-ios.swiftinterface"),
                   "-I", str(source / "idevice"), "-I", str(source / "iokit"),
                   "-L", str(source / "idevice"), "-Xlinker", "-hidden-lidevice_ffi",
                   "-Xlinker", "-dead_strip", "-Xlinker", "-install_name",
                   "-Xlinker", "@rpath/StikJIT.framework/StikJIT"]
        for name in ["JavaScriptCore", "Network", "Security", "CFNetwork",
                     "SystemConfiguration", "IOKit"]:
            command.extend(["-framework", name])
        command.extend([str(p) for p in sorted((source / "Sources").glob("*.swift"))])
        command.extend(["-o", str(framework / "StikJIT")])
        subprocess.run(command, check=True)
        if "_OBJC_CLASS_$_NSDuoPairingRuntime" not in run("nm", "-gU", str(framework / "StikJIT")):
            raise SystemExit("本机首次配对入口未导出，不能打包此 JIT 组件。")
        # swiftc places its dSYM beside the output executable, inside this bundle.
        # Keep symbols for diagnostics outside the framework: Xcode otherwise
        # tries to strip them as an embedded runtime binary during its copy step.
        symbols = framework / "StikJIT.dSYM"
        if symbols.exists():
            saved_symbols = BUILD / "StikJIT.framework.dSYM"
            if saved_symbols.exists():
                shutil.rmtree(saved_symbols)
            shutil.move(str(symbols), saved_symbols)
        # The main App build signs the embedded copy, keeping this source input stable.
        for item in DEST.iterdir():
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()
        shutil.copytree(framework, DEST, dirs_exist_ok=True)
        stamp_path.write_text(json.dumps({"inputs": signature,
                                         "binary": digest(DEST / "StikJIT")}, indent=2))
        print("已生成支持本机首次配对、完整 64 位地址和逐页校验响应的 StikJIT。")


if __name__ == "__main__":
    main()
