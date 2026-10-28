#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
mkdir -p "$NSDUO_ROOT/.toolchain/downloads" "$DOTNET_CLI_HOME" "$NUGET_PACKAGES"
if [ ! -x "$DOTNET_ROOT/dotnet" ]; then
  curl --fail --location --proto '=https' --tlsv1.2 \
    https://dot.net/v1/dotnet-install.sh \
    --output "$NSDUO_ROOT/.toolchain/downloads/dotnet-install.sh"
  bash "$NSDUO_ROOT/.toolchain/downloads/dotnet-install.sh" \
    --version 10.0.100 --architecture arm64 --install-dir "$DOTNET_ROOT" --no-path
fi
cd "$NSDUO_ROOT"
python3 tools/nsduo/fetch-dependencies.py
"$DOTNET_ROOT/dotnet" --version
# The core targets net10.0 with the ios-arm64 NativeAOT runtime pack, not
# net10.0-ios / MAUI. Its runtime/compiler packs are restored through NuGet.
"$DOTNET_ROOT/dotnet" restore src/Ryujinx.Library
echo "依赖已准备到工程 .toolchain 目录；没有修改全局 shell 配置。"
