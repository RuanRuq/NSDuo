#!/usr/bin/env python3
"""Check an already signed NS Duo .app before installing it on iOS."""

import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess


NETWORK_EXTENSION = "com.apple.developer.networking.networkextension"
PACKET_TUNNEL = "packet-tunnel-provider"
TEAM_IDENTIFIER = "com.apple.developer.team-identifier"


def read_plist(*command):
    result = subprocess.run(command, capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def check_bundle(bundle, needs_vpn, needs_debugging=False):
    if not bundle.is_dir():
        raise ValueError("安装包缺少这个组件")

    signed = read_plist("codesign", "--display", "--entitlements", "-", "--xml", str(bundle))
    profile_path = bundle / "embedded.mobileprovision"
    if not profile_path.is_file():
        raise ValueError("缺少 Apple 开发描述文件（embedded.mobileprovision）")
    profile = read_plist("security", "cms", "-D", "-i", str(profile_path))
    allowed = profile.get("Entitlements", {})

    for name, entitlements in (("签名", signed), ("描述文件", allowed)):
        if needs_vpn and PACKET_TUNNEL not in entitlements.get(NETWORK_EXTENSION, []):
            raise ValueError(f"{name}缺少 Packet Tunnel 权限")
        if needs_debugging and entitlements.get("get-task-allow") is not True:
            raise ValueError(f"{name}缺少 get-task-allow，请使用 Apple Development 签名")

    expiration = profile.get("ExpirationDate")
    if not expiration or expiration <= datetime.now(timezone.utc).replace(tzinfo=None):
        raise ValueError("描述文件已过期或缺少有效期")

    bundle_id = plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleIdentifier"]
    app_id = signed.get("application-identifier", "")
    prefix, _, signed_bundle_id = app_id.partition(".")
    allowed_id = allowed.get("application-identifier", "")
    if (signed_bundle_id != bundle_id or prefix not in profile.get("ApplicationIdentifierPrefix", [])
            or not (app_id == allowed_id or (allowed_id.endswith(".*") and app_id.startswith(allowed_id[:-1])))):
        raise ValueError("Bundle ID、签名和描述文件中的 App ID 不匹配")
    team = signed.get(TEAM_IDENTIFIER)
    if not team or team != allowed.get(TEAM_IDENTIFIER) or team not in profile.get("TeamIdentifier", []):
        raise ValueError("签名和描述文件的开发团队不匹配")

    # Verify the bundle seal and Apple signing chain. iOS still checks device
    # registration and provisioning when the app is installed.
    subprocess.run(["codesign", "--verify", "--strict", "-R=anchor apple generic", str(bundle)],
                   capture_output=True, check=True)
    return bundle_id, team


def main():
    parser = argparse.ArgumentParser(description="检查已签名的 NS Duo App 和扩展")
    parser.add_argument("app", type=Path, help="已签名的 .app（IPA 解压后在 Payload 中）")
    app = parser.parse_args().app.resolve()
    targets = [
        (app, True, True),
        (app / "PlugIns/NSDuoTunnel.appex", True, False),
        (app / "PlugIns/NSDuoJITHelper.appex", False, False),
    ]
    results = []
    for bundle, needs_vpn, needs_debugging in targets:
        try:
            results.append(check_bundle(bundle, needs_vpn, needs_debugging))
        except subprocess.CalledProcessError as error:
            detail = error.stderr.decode(errors="replace").strip()
            parser.exit(1, f"{bundle.name}：{error.cmd[0]} 检查失败：{detail}\n")
        except (OSError, KeyError, TypeError, ValueError, plistlib.InvalidFileException) as error:
            parser.exit(1, f"{bundle.name}：{error}\n")

    host_id, host_team = results[0]
    for (bundle, _, _), (bundle_id, team) in zip(targets[1:], results[1:]):
        if team != host_team or not bundle_id.startswith(host_id + "."):
            parser.exit(1, f"{bundle.name}：必须与主 App 使用同一开发团队，Bundle ID 也必须以主 App 的 Bundle ID 加点号开头。\n")
    print("签名检查通过：主 App 有开发调试权限，主 App 和 VPN 扩展均有 Packet Tunnel 权限，JIT 扩展也已签名。")


if __name__ == "__main__":
    main()
