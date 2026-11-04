#!/usr/bin/env python3
"""Statically compare the actual C# signal declarations with the iPhoneOS SDK.

Only clang -fsyntax-only is invoked. No app/core/test executable is built or run.
"""
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'work/signal-abi-checks'
OUT.mkdir(parents=True, exist_ok=True)
DEVELOPER = Path(os.environ.get('NSDUO_DEVELOPER_DIR', os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')))
SDK = DEVELOPER / 'Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk'
CLANG = DEVELOPER / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'


def block(text, declaration):
    start = text.index('{', text.index(declaration)) + 1
    end, depth = start, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end - 1]


source = (ROOT / 'src/Ryujinx.Cpu/Signal/UnixSignalHandlerRegistration.cs').read_text()
declaration = block(source, 'struct DarwinSigAction')
assert re.search(r'\[StructLayout\(LayoutKind.Sequential\)\]\s*internal struct DarwinSigAction', source)
fields = re.findall(r'public\s+(\w+)\s+(\w+)\s*;', declaration)
assert len(fields) == declaration.count(';'), 'Unrecognized native field declaration'
types = {'nint': 'void *', 'uint': 'uint32_t', 'int': 'int32_t'}
native = '\n'.join(f'{types[kind]} {name};' for kind, name in fields)
flag = int(re.search(r'const int DarwinSigInfo = (0x[0-9a-fA-F]+|\d+);', source)[1], 0)
probe = '#include <signal.h>\n#include <stddef.h>\n#include <stdint.h>\n'
probe += 'struct ManagedDarwinSigAction {\n' + native + '\n};\n'
probe += '_Static_assert(sizeof(struct ManagedDarwinSigAction) == sizeof(struct sigaction), "sigaction size mismatch");\n'
for managed, system in [('Handler', 'sa_handler'), ('Mask', 'sa_mask'), ('Flags', 'sa_flags')]:
    probe += f'_Static_assert(offsetof(struct ManagedDarwinSigAction, {managed}) == offsetof(struct sigaction, {system}), "{managed} offset mismatch");\n'
probe += f'_Static_assert({flag} == SA_SIGINFO, "SA_SIGINFO mismatch");\n'
file = OUT / 'darwin-signal-abi.c'
file.write_text(probe)
subprocess.run([str(CLANG), '-fsyntax-only', '-target', 'arm64-apple-ios17.4', '-isysroot', str(SDK), str(file)], check=True)

# The generated handler uses a packed C# configuration. Verify its offsets and
# read widths together, so adding another callback cannot shift tracked ranges
# or accidentally read an adjacent field as part of a 32-bit boolean flag.
config_source = (ROOT / 'src/Ryujinx.Cpu/Signal/NativeSignalHandler.cs').read_text()
config = block(config_source, 'struct SignalHandlerConfig')
assert re.search(r'\[StructLayout\(LayoutKind.Sequential, Pack = 1\)\]\s*struct SignalHandlerConfig', config_source)
config_fields = re.findall(r'public\s+(\w+)\s+(\w+)\s*;', config)
sizes = {'int': 4, 'nuint': 8}
offsets, widths, offset = {}, {}, 0
for kind, name in config_fields:
    offsets[name] = offset
    if kind == 'SignalHandlerRangeArray':
        assert name == 'Ranges' and (kind, name) == config_fields[-1]
        break
    widths[name] = sizes[kind]
    offset += sizes[kind]

generator = (ROOT / 'src/ARMeilleure/Signal/NativeSignalHandlerGenerator.cs').read_text()
for name in ['UnixOldSigaction', 'UnixOldSigaction3Arg', 'UnixOldSigbus', 'UnixOldSigbus3Arg', 'RangeOffset']:
    value = int(re.search(rf'const int {name} = (\d+);', generator)[1])
    field = 'Ranges' if name == 'RangeOffset' else name
    assert value == offsets[field], f'{name}: generated {value}, managed {offsets[field]}'
    if field != 'Ranges':
        reads = re.findall(rf'context.Load\(OperandType.I(32|64), Const\(\(ulong\)signalStructPtr \+ {name}\)\)', generator)
        assert reads and all(int(bits) // 8 == widths[field] for bits in reads), f'{name}: incorrect native load width'
print('PASS static signal ABI: iPhoneOS SDK size/offsets/SA_SIGINFO; packed handler offsets and load widths. No runtime tests executed.')
