#!/usr/bin/env python3
"""Host-only regression checks: no simulator, signing, or app installation.
Runs real Swift implementations; extracts Foundation-only library types from the
UIKit store and C# host-loop methods with native/hardware boundaries stubbed.
"""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
TESTS = Path(__file__).resolve().parent
OUT = ROOT / 'work/runtime-checks'
OUT.mkdir(parents=True, exist_ok=True)
SWIFT = ROOT / 'src/MeloNX/MeloNX'
ENV = dict(os.environ)
ENV['TMPDIR'] = str(OUT)
ENV.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')

def block(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

store = (SWIFT / 'Core/Duo/NSDuoLibraryStore.swift').read_text()
package = (SWIFT / 'Core/Duo/NSDuoPackageInspector.swift').read_text()
types = ['nonisolated enum NSDuoGameFormat:', 'nonisolated struct NSDuoLibraryGame:',
         'nonisolated struct NSDuoImportProgress:', 'nonisolated enum NSDuoLibraryIO',
         'nonisolated enum LibraryError:', 'nonisolated final class NSDuoImportOperation:']
(OUT / 'LibraryTypes.swift').write_text('import Foundation\nimport CryptoKit\n' +
    '\n\n'.join(block(store, kind) for kind in types) + '\n' +
    block(package, 'nonisolated struct NSDuoPackageContent:'))
folder = (SWIFT / 'Core/Duo/NSDuoFolderLibrary.swift').read_text()
# Visibility only: exercise the actual streaming implementation for corruption/cancellation.
(OUT / 'FolderIO.swift').write_text(folder.replace('private static func streamCopy(', 'static func streamCopy('))
sources = [SWIFT / p for p in ['Core/Callbacks/CallbackManager.swift', 'Core/Models/CallbackData.swift',
    'Common/StatisticsHandler.swift', 'Core/Duo/NSDuoTouchSlots.swift',
    'Core/Controllers/Motion/ControllerMotionSession.swift', 'Core/Controllers/Rumble/RumbleController.swift', 'Core/Models/RumbleData.swift']]
menu = (SWIFT / 'UI/Emulation/Config/InGameConfigView.swift').read_text()
(OUT / 'Menu.swift').write_text('import Foundation\nimport Combine\n@MainActor\n' + block(menu, 'class InGameConfigView_MenuView:'))
sources.append(OUT / 'Menu.swift')
hold_control = (SWIFT / 'UI/Duo/NSDuoHoldToRemoveButton.swift').read_text()
(OUT / 'HoldConfirmation.swift').write_text('import Foundation\n' + block(hold_control, 'nonisolated struct NSDuoHoldConfirmation'))
sources.append(OUT / 'HoldConfirmation.swift')
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
    '-module-cache-path', str(OUT / 'ModuleCache'), *map(str, sources),
    str(OUT / 'LibraryTypes.swift'), str(OUT / 'FolderIO.swift'),
    str(TESTS / 'RuntimeChecks.swift'), '-o', str(OUT / 'swift-checks')], env=ENV, check=True)
subprocess.run([str(OUT / 'swift-checks')], env=ENV, check=True, timeout=30)

window = (ROOT / 'src/Ryujinx.Library/Window/WindowBase.cs').read_text()
methods = '\n'.join(block(window, signature) for signature in [
    'private void SignalInputUpdated()', 'public void RequestPause(bool shouldPause)',
    'public void RequestExit()', 'public void MainLoop()'])
(OUT / 'WindowLoopChecks.cs').write_text((TESTS / 'WindowLoopChecks.cs.template').read_text().replace('/* PRODUCTION_METHODS */', methods))
(OUT / 'LoopChecks.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>
<EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableNETAnalyzers>false</EnableNETAnalyzers>
</PropertyGroup><ItemGroup><Compile Include="WindowLoopChecks.cs" /></ItemGroup></Project>''')
# No feeds or packages needed. Keep all CLI and SDK caches within the project.
(OUT / 'NuGet.Config').write_text('<configuration><packageSources><clear /></packageSources></configuration>')
ENV.update(DOTNET_CLI_HOME=str(OUT / 'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
           DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1',
           DOTNET_GENERATE_ASPNET_CERTIFICATE='false', NUGET_PACKAGES=str(ROOT / '.toolchain/nuget/packages'))
dotnet = ROOT / '.toolchain/dotnet/dotnet'
subprocess.run([str(dotnet), 'run', '--project', str(OUT / 'LoopChecks.csproj'), '--verbosity', 'quiet'],
               cwd=OUT, env=ENV, check=True, timeout=90)
print('PASS: all host regression checks (not a device performance benchmark)', flush=True)
