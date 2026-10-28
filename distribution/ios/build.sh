#!/usr/bin/env bash
set -euo pipefail
NSDUO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$NSDUO_ROOT/tools/nsduo/environment.sh"
cd "$NSDUO_ROOT"
if [ ! -x "$DOTNET_ROOT/dotnet" ]; then
  echo "缺少工程内 .NET SDK。请先运行 tools/nsduo/setup-local.sh。" >&2
  exit 1
fi
# A manual core build and Xcode may overlap while provisioning is prepared.
# Lock the publish directory; every invocation still runs the incremental build.
python3 - "$DOTNET_ROOT/dotnet" "$NSDUO_ROOT" <<'PY'
import fcntl
import pathlib
import subprocess
import sys

dotnet, root = sys.argv[1:]
lock_dir = pathlib.Path(root) / ".build"
lock_dir.mkdir(exist_ok=True)
with (lock_dir / "core-publish.lock").open("w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    result = subprocess.run([
        dotnet, "publish", "-c", "Release", "-r", "ios-arm64",
        "-p:ExtraDefineConstants=DISABLE_UPDATER", "src/Ryujinx.Library",
        "--self-contained", "true",
    ], cwd=root)
    sys.exit(result.returncode)
PY
