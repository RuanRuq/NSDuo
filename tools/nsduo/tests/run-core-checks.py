#!/usr/bin/env python3
"""Exercise real renderer, touch and NSZ code on the host; no iOS app build."""
import os
from pathlib import Path
import subprocess
import xml.sax.saxutils as xml
ROOT = Path(__file__).resolve().parents[3]
TESTS = Path(__file__).resolve().parent
OUT = ROOT / 'work/core-runtime-checks'
OUT.mkdir(parents=True, exist_ok=True)
refs = {name: ROOT / f'src/{name}/bin/Release/net10.0/{name}.dll' for name in
        ['Ryujinx.Common', 'Ryujinx.Graphics.Shader', 'Ryujinx.Input']}
refs['ZstdSharp'] = ROOT / '.toolchain/nuget/packages/zstdsharp.port/0.8.8/lib/net9.0/ZstdSharp.dll'
for path in refs.values():
    if not path.exists(): raise SystemExit(f'Prepare project dependencies/core first: {path}')
# Reuse the actual ProgressHandler, with only its enclosing game-runtime type omitted.
def block(text, signature):
    start = text.index(signature); opening = text.index('{', start); depth = 1; end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]
progress = block((ROOT / 'src/Ryujinx.Library/Library.cs').read_text(), 'private static unsafe void ProgressHandler<T>')
(OUT / 'ProgressChecks.cs').write_text('using System; using System.Text; using Ryujinx.Common.Callbacks;\n'
    'enum LoadState { Loading, Loaded } enum ShaderCacheState { Loading, Loaded }\n'
    'partial class CoreChecks {\n' + progress + '\n}')
sources = [str(p) for p in (ROOT / 'src/Ryujinx.Graphics.GAL').rglob('*.cs')
           if not any(part in ('bin', 'obj') for part in p.parts)]
sources += [str(ROOT / p) for p in ['src/Ryujinx.Library/Compression/NszDecompressor.cs',
    'src/Ryujinx.Library/Compression/NativeNsz.cs', 'src/Ryujinx.Library/Native/NativeTouchDriver.cs',
    'src/Ryujinx.Library/Native/NativeMouse.cs', 'src/Ryujinx.Input.Native/NativeGamepad.cs',
    'src/Ryujinx.Input.Native/NativeGamepadDriver.cs', 'src/Ryujinx.Common/Callbacks/CallbackRegistry.cs',
    'src/Ryujinx.Common/Logging/GameDiagnostics.cs', 'src/Ryujinx.Common/Logging/GraphicsTiming.cs']]
window = (ROOT / 'src/Ryujinx.Library/Window/WindowBase.cs').read_text()
methods = '\n'.join(block(window, signature) for signature in ['public void Render()',
    'private void SignalGpuDoneBeforeWorkerStart()', 'private void RecordRenderFailure(Exception error)'])
(OUT / 'WindowRenderChecks.cs').write_text('using System; using System.Threading; using Ryujinx.Common.Logging; using Ryujinx.Graphics.GAL; '
    'using Ryujinx.Graphics.GAL.Multithreading;\n' +
    'class WindowRenderChecks { public class GpuModel { public IRenderer Renderer; } '
    'public class DeviceModel { public GpuModel Gpu = new(); } public DeviceModel Device = new(); '
    'public ManualResetEvent _gpuDoneEvent = new(false); bool _exitRequested; Exception _renderFailure; '
    'public Action Run; void RenderCore() => Run(); void RequestExit() => _exitRequested = true; '
    'void FinalizeWindowRenderer() {} ' + methods + '}')
sources += [str(TESTS / 'CoreChecks.cs'), str(OUT / 'ProgressChecks.cs'), str(OUT / 'WindowRenderChecks.cs')]
items = ''.join(f'<Compile Include="{xml.escape(p)}" />' for p in sources)
items += ''.join(f'<Reference Include="{name}"><HintPath>{xml.escape(str(path))}</HintPath></Reference>' for name,path in refs.items())
(OUT / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><LangVersion>preview</LangVersion>'
    '<AllowUnsafeBlocks>true</AllowUnsafeBlocks><EnableDefaultCompileItems>false</EnableDefaultCompileItems>'
    '<EnableNETAnalyzers>false</EnableNETAnalyzers><NoWarn>CS0436;CS0067</NoWarn>'
    '</PropertyGroup><ItemGroup>' + items + '</ItemGroup></Project>')
(OUT / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
env = dict(os.environ, DOTNET_CLI_HOME=str(OUT/'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
    DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false',
    NUGET_PACKAGES=str(ROOT / '.toolchain/nuget/packages'))
subprocess.run([str(ROOT/'.toolchain/dotnet/dotnet'), 'run', '--project', str(OUT/'Checks.csproj'), '--verbosity', 'quiet'],
    cwd=OUT, env=env, check=True, timeout=90)
