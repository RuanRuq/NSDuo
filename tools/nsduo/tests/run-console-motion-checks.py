#!/usr/bin/env python3
"""Host-only checks of console rotation and per-game motion preference storage."""
import os
from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'work/console-motion-checks'
OUT.mkdir(parents=True, exist_ok=True)
TESTS = Path(__file__).parent
SWIFT = ROOT / 'src/MeloNX/MeloNX'
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', TMPDIR=str(OUT),
           DOTNET_CLI_HOME=str(OUT/'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
           DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1',
           NUGET_PACKAGES=str(ROOT/'.toolchain/nuget/packages'))
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
    '-module-cache-path', str(OUT/'ModuleCache'),
    str(SWIFT/'Core/Duo/NSDuoConsoleLog.swift'),
    str(SWIFT/'Core/Controllers/Motion/ControllerMotionSession.swift'),
    str(TESTS/'ConsoleAndMotionChecks.swift'), '-o', str(OUT/'swift-checks')], env=env, check=True)
subprocess.run([str(OUT/'swift-checks'), str(OUT)], env=env, check=True, timeout=30)
sources = [ROOT/'src/Ryujinx.Common/Logging/Targets/ConsoleRepeatFilter.cs',
           ROOT/'src/Ryujinx.Common/Logging/Targets/AsyncLogTargetWrapper.cs',
           ROOT/'src/Ryujinx.Common/Logging/Targets/ILogTarget.cs',
           ROOT/'src/Ryujinx.Common/Logging/LogEventArgs.cs',
           ROOT/'src/Ryujinx.Common/Logging/LogLevel.cs', TESTS/'ConsoleRepeatChecks.cs']
items = ''.join(f'<Compile Include="{escape(str(p))}" />' for p in sources)
(OUT/'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><UseAppHost>false</UseAppHost>'
    '<EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup>'
    + items + '</ItemGroup></Project>')
(OUT/'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
subprocess.run([str(ROOT/'.toolchain/dotnet/dotnet'), 'run', '--project', str(OUT/'Checks.csproj'),
    '--verbosity', 'quiet'], cwd=OUT, env=env, check=True, timeout=90)
