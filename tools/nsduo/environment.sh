#!/usr/bin/env bash
# Source this file; tooling and dependency caches remain inside this project.
NSDUO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export DOTNET_ROOT="$NSDUO_ROOT/.toolchain/dotnet"
export DOTNET_CLI_HOME="$NSDUO_ROOT/.toolchain/dotnet-home"
export NUGET_PACKAGES="$NSDUO_ROOT/.toolchain/nuget/packages"
export NUGET_HTTP_CACHE_PATH="$NSDUO_ROOT/.toolchain/nuget/http-cache"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_MULTILEVEL_LOOKUP=0
export DOTNET_NOLOGO=1
export PATH="$DOTNET_ROOT:$PATH"
# Select Xcode for this build without changing global xcode-select settings.
if [ -n "${NSDUO_DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR="$NSDUO_DEVELOPER_DIR"
elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
