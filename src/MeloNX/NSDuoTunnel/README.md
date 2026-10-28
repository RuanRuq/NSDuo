# NS Duo 本地隧道来源

本扩展基于 [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) 的 `TunnelProv/PacketTunnelProvider.swift`、`TunnelProv/CIDRValidator.swift` 和 `LocalDevVPN/Constants.swift`，原作者包括 SideStore Team、Stossy11 和 Magesh K。引用版本为 `af3fd697803ada4ac2b8d518358f5ab0a534844c`。

保留本目录的 `LICENSE.txt`（StosVPN License）及 `LICENSE-original-MIT.txt`。NS Duo 的改动包括：固定原默认接口 `10.7.1.1/32` 与单一目标 `10.7.0.1/32`，移除自定义路由设置，按字节交换 IPv4 源/目的地址，并处理停止生命周期。它仅为设备本地开发连接提供路由，不连接外部 VPN 服务，不承担 JIT 成功判定。NS Duo 与 LocalDevVPN 是不同项目。
