#!/usr/bin/env python3
"""Exercise production MainActor scheduling and cover budget with controlled native boundaries."""
import os, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
TESTS=Path(__file__).resolve().parent
OUT=ROOT/'work/performance-implementation-20261030/library-scheduling'
OUT.mkdir(parents=True,exist_ok=True)
SWIFT=ROOT/'src/MeloNX/MeloNX'
def block(text, signature):
    start=text.index(signature); opening=text.index('{',start); depth=1; end=opening+1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]
s=(SWIFT/'Core/Duo/NSDuoLibraryStore.swift').read_text()
f=(SWIFT/'Core/Duo/NSDuoFolderLibrary.swift').read_text()
c=(SWIFT/'Core/Duo/NSDuoCoverIO.swift').read_text()
p=(SWIFT/'Core/Duo/NSDuoPackageInspector.swift').read_text()
parts=[block(s,x) for x in ['nonisolated enum NSDuoGameFormat:', 'nonisolated struct NSDuoLibraryGame:', 'nonisolated struct NSDuoImportProgress:', 'nonisolated enum LibraryError:', 'nonisolated final class NSDuoImportOperation:', 'nonisolated enum NSDuoLibraryWorker']]
parts += [block(f,x) for x in ['nonisolated struct NSDuoFolderRecord:', 'nonisolated struct NSDuoFolderFile:', 'nonisolated struct NSDuoIgnoredFolderFile:', 'nonisolated struct NSDuoContentSelection:']]
parts += [block(p,'nonisolated struct NSDuoPackageContent:'),block(c,'nonisolated struct NSDuoCoverBudget')]
parts += ['@MainActor\n'+block(s,'final class NSDuoLibraryStore:').replace('private init()', 'init()')]
(OUT/'Production.swift').write_text('import Foundation\nimport Combine\nimport CryptoKit\n'+ '\n\n'.join(parts))
env=dict(os.environ, TMPDIR=str(OUT))
subprocess.run(['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc','-sdk','/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk','-swift-version','5','-parse-as-library','-module-cache-path',str(OUT/'ModuleCache'),str(OUT/'Production.swift'),str(TESTS/'LibrarySchedulingChecks.swift'),'-o',str(OUT/'checks')],env=env,check=True)
subprocess.run([str(OUT/'checks')],env=env,check=True,timeout=30)
