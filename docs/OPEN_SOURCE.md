# 开源来源与许可 / Source provenance and licensing

[简体中文说明](../README.md#开源来源与感谢) · [English overview](../README.en.md#open-source-acknowledgments)

## NS Duo

原创增量代码按根目录 [MIT 许可](../LICENSE.txt) 提供；已注明来源和许可的改编文件以各自声明为准。这不是对全部上游代码重新授权。

Original NS Duo additions use the root [MIT license](../LICENSE.txt), except files with an identified upstream origin or separate license. This does not relicense upstream material.

## MeloNX / Ryujinx

- Source mirror: https://github.com/nurtrino/MeloNX
- Baseline: `f925129209afd55927a0201d82285b8fa4b7ba30`
- Ryujinx Team and Contributors retain their copyright.
- Upstream `LICENSE.txt` at this revision contains MIT. Upstream `README.md` separately states: “This software is licensed under the terms of the GPLv3 license.”
- Both statements are retained here; [GPLv3 text](../distribution/legal/GPL-3.0.txt) and the original [MIT text](../LICENSE.txt) are supplied. Do not infer a single uniform license for the entire inherited tree. File-level notices and third-party terms remain applicable.
- 中文：固定镜像中存在 README 宣称 GPLv3、根 LICENSE 实为 MIT 的差异。本项目如实保留双方声明，不宣称因此取得重授全部第三方代码许可的权利。

NS Duo adds folder/content management, NSZ import, Duo controls, integrated tunnel/JIT extensions, preparation state handling, exit cleanup and default shader-cache behavior. The emulator itself is inherited, not independently reimplemented.

## LocalDevVPN

Based on and uses code from https://github.com/jkcoxson/LocalDevVPN at `af3fd697803ada4ac2b8d518358f5ab0a534844c`.

Authors: **SideStore Team, Stossy11, Magesh K**. Derived files include `PacketTunnelProvider.swift`, `CIDREndpoint.swift` (from CIDRValidator) and `Constants.swift`. NS Duo changes routing, packet processing and shutdown handling. It does not copy the complete app UI or use LocalDevVPN branding.

Preserved [StosVPN license and original MIT notice](../distribution/legal/LocalDevVPN-LICENSE.txt); these include attribution and redistribution/rebranding conditions. This component is not represented as plain MIT. NS Duo is not an official LocalDevVPN release.

中文：内置隧道使用并修改 LocalDevVPN 代码；保留其自定义许可、原始 MIT 声明及作者署名。不得将该组件简单归为 MIT。

## StikJIT / StikDebug / idevice

- StikJIT 1.9.0: https://github.com/StikDebug/StikJIT/tree/32287268fa5824f9edce4cb359f5833ce0cf7b00 — [MPL-2.0](../distribution/legal/StikJIT/MPL-2.0.txt).
- Modified MPL source: [`tools/nsduo/stikjit`](../tools/nsduo/stikjit). Rebuild: [`build-stikjit.py`](../tools/nsduo/build-stikjit.py).
- Changes preserve full 64-bit debugserver page addresses, verify each page-write response and drain pending replies before failure.
- Original source archive is fetched by SHA-256 through `fetch-dependencies.py`; the URL, revision and digest are recorded in [provenance.json](../distribution/legal/StikJIT/provenance.json). It is not silently replaced by a newer release.
- [idevice](https://github.com/jkcoxson/idevice), Jackson Coxson and contributors: [MIT](../distribution/legal/StikJIT/idevice-MIT.txt). StikJIT's archive contains a prebuilt idevice FFI library without an exact revision identifier; it is retained unchanged, and its exact source revision is not claimed as verified.
- Bundled `universal.js` / `legacy.js` retain the [AGPL-3.0 StikDebug license](../distribution/legal/StikJIT/AGPL-3.0-scripts.txt); their original source files are included alongside that license. They are not relicensed as MPL or MIT.
- NS Duo's helper and IPC bridge are integration code. The complete StikDebug application is not copied.

中文：StikJIT、随附脚本和底层 idevice 分别适用不同许可。修改后的 MPL 源码及原始脚本均可取得；原始归档的下载地址和哈希固定记录。

## Other dependencies / 其他依赖

| Component | Use | License/reference |
| --- | --- | --- |
| NSZ / NUT format reference | NSZ container support | MIT, [notice](../src/MeloNX/MeloNX/Assets/NSZ-ThirdPartyNotices.txt) |
| ZstdSharp.Port 0.8.8 | Zstandard decompression | MIT, same notice |
| LibHac / Ryujinx.LibHac | Filesystems and package metadata | MIT; package versions in `Directory.Packages.props` |
| MoltenVK | Vulkan to Metal | Apache-2.0, upstream distribution |
| SDL3 | Multimedia / controller foundation | zlib, upstream distribution |
| FFmpeg / libvpx | Media | LGPL/GPL build-dependent FFmpeg components; BSD libvpx; preserve fetched framework licenses |
| SPIRV-Cross | Shader translation | Apache-2.0, upstream distribution |
| teakra | DSP emulation | MIT, upstream distribution |
| Melo-Controller | Controller dependency | Upstream package license |
| NavigationStackBackport | SwiftUI navigation | MIT, upstream package license |
| Atmosphère, OpenAL Soft, ShellLink | Inherited code/components, some desktop-specific | [Inherited notices](../distribution/legal/THIRDPARTY.md) |
| AmiiboAPI, ldn_mitm | Inherited upstream features | Original upstream acknowledgments; not all features exposed by NS Duo |

The NuGet manifest, Swift `Package.resolved`, source headers, fetched native framework licenses and inherited notices remain the detailed dependency records. Acknowledging an inherited dependency does not imply that every desktop feature is active on iOS.

## Research references / 调研参考

https://github.com/realskyrin/ns-game-apple-arm-port and https://github.com/jhaizhou-ops/d2r-mobile informed the initial investigation. Their game-specific compatibility layer/address patches are not included in this source tree.

## Source distribution boundary / 发布范围

This repository contains project sources, resources, build scripts and notices. It excludes personal signing settings, provisioning profiles, certificates, device records, pairing credentials, game/firmware/key files, local logs, build caches and agent work records. Downloaded dependencies retain their original license materials. The documentation's optional AI-agent instruction is usage guidance, not an agent configuration file.
