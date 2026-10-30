#!/usr/bin/env python3
"""Host-only checks for LightningJit compile sharing; no executable mapping."""
import os
from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'work/jit-sharing-checks'
OUT.mkdir(parents=True, exist_ok=True)
source_root = Path(os.environ.get('NSDUO_JIT_SOURCE_ROOT', str(ROOT)))
source = (source_root / 'src/Ryujinx.Cpu/LightningJit/Translator.cs').read_text()

def block(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

methods = block(source, 'private CompiledFunction Compile(')
platform_start = source.index('private static bool IsNoWxPlatform =>')
platform_property = source[platform_start:source.index(';', platform_start) + 1]
coordinator = source_root / 'src/Ryujinx.Cpu/LightningJit/CompilationCoordinator.cs'
sources = [Path(__file__).with_name('JitSharingChecks.cs'),
    ROOT / 'src/Ryujinx.Cpu/LightningJit/CompiledFunction.cs',
    ROOT / 'src/Ryujinx.Cpu/LightningJit/State/ExecutionMode.cs']
if coordinator.exists():
    sources.append(coordinator)
    methods += '\n' + block(source, 'private CompiledFunction CompileCore(')
    assert '_compilationCoordinator.Invalidate();' in block(source, 'public void InvalidateJitCacheRegion(')
    assert '_compilationCoordinator.Dispose();' in block(source, 'protected virtual void Dispose(')
    extra = '''readonly CompilationCoordinator _compilationCoordinator = new();
        readonly CompilationCoordinator.CompileFunction _compileFunction;
        public Translator() { _compileFunction = CompileCore; }
        public long Merged => _compilationCoordinator.GetStatistics().Merged;
        public long Retries => _compilationCoordinator.GetStatistics().Retries;
        public long Copies => _compilationCoordinator.GetStatistics().Copies;
        public void Invalidate() => _compilationCoordinator.Invalidate();
        public void Close() => _compilationCoordinator.Dispose();'''
else:
    extra = '''public long Merged => 0; public long Retries => 0; public long Copies => 0;
        public void Invalidate() { } public void Close() { }'''
(OUT / 'TranslatorMethods.cs').write_text('''using System.Runtime.InteropServices;
using Ryujinx.Cpu.LightningJit.State;
namespace Ryujinx.Cpu.LightningJit {
sealed class Translator {
    object Memory = new(), FunctionTable = new(); Stub Stubs = new();
    sealed class Stub { public nint DispatchStub; }
    public static bool PlatformIOS;
    public delegate CompiledFunction CompileHook(ulong address, ExecutionMode mode);
    public static CompileHook Hook;
    public CompiledFunction Invoke(ulong address, ExecutionMode mode) => Compile(address, mode);
''' + platform_property + '\n' + extra + '\n' + methods + '''
}
// Select the platform at the OS boundary; Compile and its platform predicate
// are extracted unchanged from the production Translator.
static class OperatingSystem { public static bool IsIOS() => Translator.PlatformIOS; }
static class CpuPresets { public static object CortexA57 = new(); }
static class AarchCompiler {
    public static CompiledFunction Compile(object preset, object memory, ulong address, object table,
        nint stub, ExecutionMode mode, Architecture architecture) => Translator.Hook(address, mode);
}
}''')
sources.append(OUT / 'TranslatorMethods.cs')
items = ''.join(f'<Compile Include="{escape(str(p))}" />' for p in sources)
(OUT / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><LangVersion>preview</LangVersion>'
    '<EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableNETAnalyzers>false</EnableNETAnalyzers>'
    '<UseSharedCompilation>false</UseSharedCompilation><NoWarn>CS0649</NoWarn>'
    '</PropertyGroup><ItemGroup>' + items + '</ItemGroup></Project>')
(OUT / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
env = dict(os.environ, DOTNET_CLI_HOME=str(OUT / 'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
    DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false',
    NUGET_PACKAGES=str(ROOT / '.toolchain/nuget/packages'))
subprocess.run([str(ROOT / '.toolchain/dotnet/dotnet'), 'run', '--project', str(OUT / 'Checks.csproj'),
    '--verbosity', 'quiet'], cwd=OUT, env=env, check=True, timeout=90)
