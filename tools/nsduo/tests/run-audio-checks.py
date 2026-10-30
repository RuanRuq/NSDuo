#!/usr/bin/env python3
"""Exercise the production SDL session/ring on the host, with a fake SDL boundary."""
import os
from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'work/audio-checks'
OUT.mkdir(parents=True, exist_ok=True)
# Two scheduling hooks in the generated copy make the publication race repeatable.
# Production methods, queue accounting, and the ring buffer otherwise stay intact.
source_root = Path(os.environ.get('NSDUO_AUDIO_SOURCE_ROOT', str(ROOT)))
source = (source_root / 'src/Ryujinx.Audio.Backends.SDL3/SDL3HardwareDeviceSession.cs').read_text()
write = '_ringBuffer.Write(buffer.Data, 0, buffer.Data.Length);'
assert source.count(write) == 1
source = source.replace(write, write + '\n                AudioHooks.AfterPcmWritten?.Invoke();')
callback = 'private unsafe void Update(nint userdata, SDL_AudioStream* streamDevice, int additionalAmount, int totalAmmount)\n        {'
assert source.count(callback) == 1
source = source.replace(callback, callback + '\n            AudioHooks.CallbackEntered?.Invoke();')
(OUT / 'Session.cs').write_text(source)
span_owner = (ROOT / 'src/Ryujinx.Common/Memory/SpanOwner.cs').read_text()
span_owner = span_owner.replace('public static SpanOwner<T> Rent(int length) => new(length);',
    'public static SpanOwner<T> Rent(int length) { System.Threading.Interlocked.Increment(ref MemoryHooks.SpanRents); return new(length); }')
(OUT / 'SpanOwner.cs').write_text(span_owner)
sources = [OUT / 'Session.cs', OUT / 'SpanOwner.cs', Path(__file__).with_name('AudioChecks.cs')]
sources += [ROOT / p for p in [
    'src/Ryujinx.Audio.Backends.SDL3/SDL3AudioBuffer.cs',
    'src/Ryujinx.Common/Memory/MemoryOwner.cs',
    'src/Ryujinx.Audio/Backends/Common/DynamicRingBuffer.cs',
    'src/Ryujinx.Audio/Backends/Common/HardwareDeviceSessionOutputBase.cs',
    'src/Ryujinx.Audio/Backends/Common/BackendHelper.cs',
    'src/Ryujinx.Audio/Common/AudioBuffer.cs',
    'src/Ryujinx.Audio/Common/SampleFormat.cs',
    'src/Ryujinx.Audio/Integration/IHardwareDeviceSession.cs']]
items = ''.join(f'<Compile Include="{escape(str(p))}" />' for p in sources)
(OUT / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
    '<OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>'
    '<EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableNETAnalyzers>false</EnableNETAnalyzers>'
    '<AllowUnsafeBlocks>true</AllowUnsafeBlocks><UseSharedCompilation>false</UseSharedCompilation><NoWarn>CS0649</NoWarn>'
    '</PropertyGroup><ItemGroup>' + items + '</ItemGroup></Project>')
(OUT / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
env = dict(os.environ, DOTNET_CLI_HOME=str(OUT / 'dotnet-home'),
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1', DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1',
    DOTNET_GENERATE_ASPNET_CERTIFICATE='false', NUGET_PACKAGES=str(ROOT / '.toolchain/nuget/packages'))
subprocess.run([str(ROOT / '.toolchain/dotnet/dotnet'), 'run', '--project', str(OUT / 'Checks.csproj'),
    '--verbosity', 'quiet'], cwd=OUT, env=env, check=True, timeout=90)
