#!/usr/bin/env python3
"""Host-only tests for Vulkan pipeline cache storage; no device or graphics driver."""
import os
from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'work/pipeline-checks'
OUT.mkdir(parents=True, exist_ok=True)
sources = [ROOT / 'src/Ryujinx.Graphics.Vulkan/PipelineCacheStorage.cs',
           Path(__file__).with_name('PipelineCacheChecks.cs'),
           Path(__file__).with_name('PipelineConcurrencyChecks.cs'),
           Path(__file__).with_name('PipelineDriverChecks.cs')]
def block(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

renderer = (ROOT / 'src/Ryujinx.Graphics.Vulkan/VulkanRenderer.cs').read_text()
driver_methods = '\n'.join(block(renderer, signature) for signature in [
    'internal unsafe PipelineCache CreatePipelineCache()', 'private unsafe void SavePipelineCache()'])
(OUT / 'PipelineDriverMethods.cs').write_text('using System; using System.Diagnostics; using System.Threading; '
    'using Ryujinx.Graphics.Vulkan;\nnamespace PipelineDriverChecks { sealed partial class Renderer {\n' + driver_methods + '\n} }')
sources.append(OUT / 'PipelineDriverMethods.cs')
source = (ROOT / 'src/Ryujinx.Graphics.Vulkan/PipelineState.cs').read_text()
methods = []
for kind, key in [('Compute', 'SpecializationData'), ('Graphics', 'Internal')]:
    start = source.index('lock (', source.index('Create' + kind + 'Pipeline('))
    opening = source.index('{', start)
    end = opening + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    methods.append(f'''static unsafe Auto<DisposablePipeline> {kind}(FakeRenderer gd, FakeProgram program, Barrier barrier, int key) {{
        int {key} = key, cacheKey = key, device = 0, cache = 0;
        Auto<DisposablePipeline> pipeline = null;
        Pipeline pipelineHandle = default; CreateInfo pipelineCreateInfo = default;
        bool throwOnError = false, cachePipelineFailure = false;
        Result result = Result.Success;
        // All requests saw a miss before entering the production creation block.
        if (program.TryGet{kind}Pipeline(ref {key}, out pipeline)) return pipeline;
        if (!barrier.SignalAndWait(3000)) throw new Exception("request barrier timed out");
        {'Internal ^= 1024; // Emulate a temporary Metal integer-blend workaround; the cache key must stay original.' if kind == 'Graphics' else ''}
        long requested = Stopwatch.GetTimestamp();
        {source[start:end]}
        if (result != Result.Success) return null;
        return pipeline ?? program.Add{kind}Pipeline(ref {key}, new Auto<DisposablePipeline>(new DisposablePipeline(gd.Api, device, pipelineHandle)));
    }}''')
(OUT / 'PipelineCreationBlocks.cs').write_text('using System; using System.Diagnostics; using System.Threading;\n'
    'static partial class PipelineConcurrencyChecks {\n' + '\n'.join(methods) + '\n}')
sources.append(OUT / 'PipelineCreationBlocks.cs')
items = ''.join(f'<Compile Include="{escape(str(p))}" />' for p in sources)
(OUT / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>'
    '<EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableNETAnalyzers>false</EnableNETAnalyzers><AllowUnsafeBlocks>true</AllowUnsafeBlocks><NoWarn>CS0219;CS0649</NoWarn>'
    '</PropertyGroup><ItemGroup>' + items + '</ItemGroup></Project>')
(OUT / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
env = dict(os.environ, DOTNET_CLI_HOME=str(OUT/'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
    DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false',
    TMPDIR=str(OUT), NUGET_PACKAGES=str(ROOT / '.toolchain/nuget/packages'))
subprocess.run([str(ROOT/'.toolchain/dotnet/dotnet'), 'run', '--project', str(OUT/'Checks.csproj'),
    '--verbosity', 'quiet'], cwd=OUT, env=env, check=True, timeout=90)
