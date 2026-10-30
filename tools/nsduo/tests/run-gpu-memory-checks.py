#!/usr/bin/env python3
"""Host-only production texture-cache and compilation-scheduler checks."""
import os
from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'work/gpu-memory-checks'
OUT.mkdir(parents=True, exist_ok=True)
sources = [ROOT / 'src/Ryujinx.Graphics.Gpu/Image/AutoDeleteCache.cs',
           ROOT / 'src/Ryujinx.Graphics.Vulkan/BackgroundCompilationScheduler.cs',
           Path(__file__).with_name('GpuMemoryChecks.cs'),
           Path(__file__).with_name('ShaderSchedulingChecks.cs')]
def block(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
shader = (ROOT / 'src/Ryujinx.Graphics.Vulkan/Shader.cs').read_text()
constructors = '\n'.join(block(shader, signature) for signature in [
    'public unsafe Shader(Vk api,', 'public unsafe Shader(VulkanRenderer gd,'])
collection = (ROOT / 'src/Ryujinx.Graphics.Vulkan/ShaderCollection.cs').read_text()
start = collection.index('Shader shader =')
factory = collection[start:collection.index(';', start) + 1]
(OUT / 'ShaderConstruction.cs').write_text('using System.Threading.Tasks; namespace ShaderSchedulingChecks {'
    'partial class Shader {' + constructors + '} static class Factory {'
    'public static Shader Create(VulkanRenderer gd, bool compileInBackground) {'
    'Device device = default; ShaderSource[] shaders = [new()]; int i = 0; bool highPriorityBackgroundCompilation = false;'
    + factory + ' return shader; } } }')
sources.append(OUT / 'ShaderConstruction.cs')
budget = ROOT / 'src/Ryujinx.Graphics.Gpu/Image/TextureCacheMemoryBudget.cs'
if budget.exists():
    sources.append(budget)
items = ''.join(f'<Compile Include="{escape(str(path))}" />' for path in sources)
(OUT / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><UseAppHost>false</UseAppHost>'
    '<EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableNETAnalyzers>false</EnableNETAnalyzers><AllowUnsafeBlocks>true</AllowUnsafeBlocks>'
    '</PropertyGroup><ItemGroup>' + items + '</ItemGroup></Project>')
(OUT / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
env = dict(os.environ, DOTNET_CLI_HOME=str(OUT / 'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
    DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false',
    TMPDIR=str(OUT), NUGET_PACKAGES=str(ROOT / '.toolchain/nuget/packages'))
subprocess.run([str(ROOT / '.toolchain/dotnet/dotnet'), 'run', '--project', str(OUT / 'Checks.csproj'),
    '--verbosity', 'quiet'], cwd=OUT, env=env, check=True, timeout=90)
