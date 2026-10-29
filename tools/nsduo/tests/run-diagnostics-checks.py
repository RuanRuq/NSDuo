#!/usr/bin/env python3
"""Exercise local diagnostic recording without an iOS app or device."""
import os
from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'work/diagnostics-checks'
OUT.mkdir(parents=True, exist_ok=True)
sources = [ROOT / 'src/Ryujinx.Common/Logging/GameDiagnostics.cs',
           ROOT / 'src/Ryujinx.Common/ReleaseInformation.cs', Path(__file__).with_name('DiagnosticsChecks.cs')]
items = ''.join(f'<Compile Include="{escape(str(p))}" />' for p in sources)
common = ROOT / 'src/Ryujinx.Common/bin/Release/net10.0/Ryujinx.Common.dll'
items += f'<Reference Include="Ryujinx.Common"><HintPath>{escape(str(common))}</HintPath></Reference>'
(OUT / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>'
    '<EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableNETAnalyzers>false</EnableNETAnalyzers><NoWarn>CS0436</NoWarn>'
    '</PropertyGroup><ItemGroup>' + items + '</ItemGroup></Project>')
(OUT / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
env = dict(os.environ, DOTNET_CLI_HOME=str(OUT/'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
    DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false',
    TMPDIR=str(OUT), NUGET_PACKAGES=str(ROOT / '.toolchain/nuget/packages'))
subprocess.run([str(ROOT/'.toolchain/dotnet/dotnet'), 'run', '--project', str(OUT/'Checks.csproj'),
    '--verbosity', 'quiet'], cwd=OUT, env=env, check=True, timeout=90)

# Compile the actual Foundation-only file operations, leaving the UIKit/native
# telemetry bridge out of the host executable. Every fixture stays under OUT.
swift = (ROOT/'src/MeloNX/MeloNX/Core/Duo/NSDuoDiagnostics.swift').read_text()
(OUT/'DiagnosticFiles.swift').write_text('import Foundation\n' + swift[swift.index('nonisolated struct NSDuoDiagnosticRecord:'):])
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
    '-module-cache-path', str(OUT/'SwiftModuleCache'), str(OUT/'DiagnosticFiles.swift'),
    str(Path(__file__).with_name('DiagnosticFileChecks.swift')), '-o', str(OUT/'file-checks')],
    env=env, check=True, timeout=90)
subprocess.run([str(OUT/'file-checks'), str(OUT)], env=env, check=True, timeout=30)
