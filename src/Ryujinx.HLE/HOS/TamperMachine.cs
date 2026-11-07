using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Tamper;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace Ryujinx.HLE.HOS
{
    public class TamperMachine : IDisposable
    {
        // Atmosphere executes enabled programs about twelve times per second.
        private const int TamperMachineSleepMs = 1000 / 12;
        // More than the shortest possible instructions in a 2 MiB saved document.
        private const int MaximumManagedInstructions = 256 * 1024;
        private readonly object _lock = new();
        private readonly Dictionary<string, ITamperProgram> _filePrograms = new();
        private readonly Dictionary<ulong, ProcessRegistration> _processes = new();
        private List<ITamperProgram> _managedPrograms = new();
        private Thread _tamperThread;
        private long _pressedKeys;
        private bool _disposed;

        public sealed record ManagedCheat(string BuildId, string Id, string Name, string[] Instructions);

        private sealed record ProcessRegistration(ulong ApplicationId, ProcessTamperInfo Info,
            Dictionary<string, ulong> Executables, string[] BuildIds);

        private sealed record ManagedCompilationGroup(string BuildId, ulong Address, List<string> Instructions);

        internal void RegisterProcess(ulong applicationId, ProcessTamperInfo info)
        {
            if (info?.Process == null || !CanInstallOnPid(info.Process.Pid))
            {
                return;
            }

            string[] buildIds = info.BuildIds.ToArray();
            ulong[] addresses = info.CodeAddresses.ToArray();
            Dictionary<string, ulong> executables = new(StringComparer.OrdinalIgnoreCase);
            List<string> cheatIds = new();
            for (int i = 0; i < Math.Min(buildIds.Length, addresses.Length); i++)
            {
                string fullId = buildIds[i]?.ToUpperInvariant();
                if (!IsBuildId(fullId) || addresses[i] == 0)
                {
                    continue;
                }

                string cheatId = fullId[..16];
                executables.TryAdd(fullId, addresses[i]);
                executables.TryAdd(cheatId, addresses[i]);
                if (!cheatIds.Contains(cheatId)) cheatIds.Add(cheatId);
            }

            lock (_lock)
            {
                if (_disposed || _processes.ContainsKey(info.Process.Pid)) return;
                // Keep CpuMemory alive until the worker has stopped, including natural guest exit.
                info.Process.IncrementReferenceCount();
                _processes.Add(info.Process.Pid, new(applicationId, info, executables, cheatIds.ToArray()));
            }
        }

        public bool TryGetProcessInfo(ulong applicationId, ulong processId, out string[] buildIds)
        {
            lock (_lock)
            {
                if (TryGetProcess(applicationId, processId, out ProcessRegistration process))
                {
                    buildIds = (string[])process.BuildIds.Clone();
                    return buildIds.Length != 0;
                }

                buildIds = Array.Empty<string>();
                return false;
            }
        }

        // All validation and compilation happen before replacing the managed set. An error
        // leaves the previous configuration intact; file-based cheats have a separate owner.
        public void ReplaceManagedCheats(ulong applicationId, ulong processId, IReadOnlyList<ManagedCheat> cheats)
        {
            lock (_lock)
            {
                if (!TryGetProcess(applicationId, processId, out ProcessRegistration process))
                    throw new InvalidOperationException("当前游戏尚未准备好，或已经停止。");
                if (cheats == null || cheats.Count > 1024)
                    throw new ArgumentException("金手指项目数量无效。");

                Dictionary<ulong, ManagedCompilationGroup> groupsByAddress = new();
                List<ManagedCompilationGroup> groups = new();
                HashSet<(ulong Address, string Id)> ids = new();
                int totalInstructions = 0;
                foreach (ManagedCheat cheat in cheats)
                {
                    if (cheat == null || !IsBuildId(cheat.BuildId) ||
                        !process.Executables.TryGetValue(cheat.BuildId, out ulong address))
                        throw new ArgumentException("启用的金手指 Build ID 与当前游戏版本不匹配。");
                    if (string.IsNullOrWhiteSpace(cheat.Id) || string.IsNullOrWhiteSpace(cheat.Name) ||
                        !ids.Add((address, cheat.Id)) ||
                        cheat.Instructions == null || cheat.Instructions.Length is 0 or > 16384)
                        throw new ArgumentException("金手指名称、标识或指令无效。");
                    if (cheat.Instructions.Length > MaximumManagedInstructions - totalInstructions)
                        throw new ArgumentException("启用的金手指合计超过 262144 行，请减少启用项目。");
                    totalInstructions += cheat.Instructions.Length;
                    foreach (string instruction in cheat.Instructions)
                    {
                        if (string.IsNullOrWhiteSpace(instruction) || instruction.Length > 256)
                            throw new ArgumentException($"Build ID {cheat.BuildId[..16]} 的金手指包含无效指令。");
                    }

                    // A 16-character ID and its full 64-character NSO ID can name
                    // the same module. Group by the resolved address, not the input ID.
                    if (!groupsByAddress.TryGetValue(address, out ManagedCompilationGroup group))
                    {
                        group = new(cheat.BuildId[..16].ToUpperInvariant(), address, new List<string>());
                        groupsByAddress.Add(address, group);
                        groups.Add(group);
                    }
                    group.Instructions.AddRange(cheat.Instructions);
                }

                List<ITamperProgram> prepared = new();
                foreach (ManagedCompilationGroup group in groups)
                {
                    // Atmosphere concatenates enabled entries before VM execution.
                    // One context per executable preserves master/register dependencies
                    // and runs each incoming entry once in its supplied order.
                    AtmosphereCompiler compiler = new(group.Address, process.Info.HeapAddress, process.Info.AliasAddress,
                        process.Info.AslrAddress, new TamperedKProcess(process.Info.Process));
                    ITamperProgram program = compiler.Compile($"Build ID {group.BuildId}", group.Instructions);
                    if (program == null)
                        throw new ArgumentException($"Build ID {group.BuildId} 的金手指编译失败，原有开关未修改。");
                    program.IsEnabled = true;
                    prepared.Add(program);
                }

                if (!IsRunningProcess(process.Info.Process.State))
                    throw new InvalidOperationException("当前游戏已经停止，金手指未修改。");

                List<ITamperProgram> previous = _managedPrograms;
                _managedPrograms = prepared;
                try
                {
                    ActivateLocked();
                }
                catch
                {
                    _managedPrograms = previous;
                    throw;
                }
            }
        }

        private bool TryGetProcess(ulong applicationId, ulong processId, out ProcessRegistration process)
        {
            process = null;
            return !_disposed && _processes.TryGetValue(processId, out process) &&
                process.ApplicationId == applicationId && IsRunningProcess(process.Info.Process.State);
        }

        private static bool IsBuildId(string value)
        {
            if (value == null || value.Length is not (16 or 64)) return false;
            foreach (char c in value)
            {
                if (!Uri.IsHexDigit(c)) return false;
            }
            return true;
        }

        private void ActivateLocked()
        {
            // Thread exit and replacement share this lock: an install cannot miss an
            // exiting worker, and a disabled program cannot be executing after return.
            if (_disposed || _tamperThread != null || !HasEnabledPrograms()) return;
            _tamperThread = new Thread(TamperRunner) { Name = "HLE.TamperMachine", IsBackground = true };
            try
            {
                _tamperThread.Start();
            }
            catch
            {
                _tamperThread = null;
                throw;
            }
        }

        internal void InstallAtmosphereCheat(string name, string buildId, IEnumerable<string> rawInstructions, ProcessTamperInfo info, ulong exeAddress)
        {
            lock (_lock)
            {
                if (_disposed || !CanInstallOnPid(info.Process.Pid)) return;
                AtmosphereCompiler compiler = new(exeAddress, info.HeapAddress, info.AliasAddress,
                    info.AslrAddress, new TamperedKProcess(info.Process));
                ITamperProgram program = compiler.Compile(name, rawInstructions);
                if (program != null)
                {
                    _filePrograms.TryAdd($"{buildId}-{name}", program);
                }
                ActivateLocked();
            }
        }

        private static bool CanInstallOnPid(ulong pid)
        {
            if (pid < KernelConstants.InitialProcessId)
            {
                Logger.Warning?.Print(LogClass.TamperMachine, $"Refusing to tamper kernel process {pid}");
                return false;
            }
            return true;
        }

        public void EnableCheats(string[] enabledCheats)
        {
            lock (_lock)
            {
                if (_disposed) return;
                HashSet<string> enabled = new(enabledCheats, StringComparer.Ordinal);
                foreach (var pair in _filePrograms) pair.Value.IsEnabled = enabled.Contains(pair.Key);
                ActivateLocked();
            }
        }

        public void EnableAllCheats()
        {
            lock (_lock)
            {
                if (_disposed) return;
                foreach (ITamperProgram program in _filePrograms.Values) program.IsEnabled = true;
                ActivateLocked();
            }
        }

        private static bool IsProcessValid(ProcessState state) =>
            state is not ProcessState.Crashed and not ProcessState.Exiting and not ProcessState.Exited;

        private static bool IsRunningProcess(ProcessState state) =>
            state is ProcessState.Started or ProcessState.Attached or ProcessState.DebugSuspended;

        private bool HasEnabledPrograms() => _managedPrograms.Count != 0 || _filePrograms.Values.Any(p => p.IsEnabled);

        private void TamperRunner()
        {
            Logger.Info?.Print(LogClass.TamperMachine, "TamperMachine thread running");
            lock (_lock)
            {
                try
                {
                    while (!_disposed && HasEnabledPrograms())
                    {
                        Monitor.Wait(_lock, TamperMachineSleepMs);
                        if (_disposed) break;
                        foreach (string key in _filePrograms.Where(p => !IsProcessValid(p.Value.Process.State)).Select(p => p.Key).ToArray())
                            _filePrograms.Remove(key);
                        _managedPrograms.RemoveAll(p => !IsProcessValid(p.Process.State));
                        foreach (ITamperProgram program in _filePrograms.Values) ExecuteProgram(program);
                        foreach (ITamperProgram program in _managedPrograms) ExecuteProgram(program);
                    }
                }
                finally
                {
                    _tamperThread = null;
                    Monitor.PulseAll(_lock);
                }
            }
            Logger.Info?.Print(LogClass.TamperMachine, "TamperMachine thread exiting");
        }

        private void ExecuteProgram(ITamperProgram program)
        {
            // Do not repeatedly modify memory while the user is choosing switches in
            // the suspended library. The next tick after resume applies the new set.
            if (!program.IsEnabled || program.Process.IsPaused || !IsProcessValid(program.Process.State)) return;
            try
            {
                ControllerKeys pressedKeys = (ControllerKeys)Volatile.Read(ref _pressedKeys);
                program.Process.TamperedCodeMemory = false;
                program.Execute(pressedKeys);
                if (!program.TampersCodeMemory && program.Process.TamperedCodeMemory)
                {
                    program.TampersCodeMemory = true;
                    Logger.Debug?.Print(LogClass.TamperMachine, $"Tampering program {program.Name} modifies executable memory; translated code was invalidated");
                }
            }
            catch (Exception ex)
            {
                Logger.Debug?.Print(LogClass.TamperMachine, $"The tampering program {program.Name} crashed: {ex.Message}");
            }
        }

        public void Dispose()
        {
            Thread worker;
            lock (_lock)
            {
                _disposed = true;
                _managedPrograms.Clear();
                _filePrograms.Clear();
                worker = _tamperThread;
                Monitor.PulseAll(_lock);
            }
            worker?.Join();
            lock (_lock)
            {
                ProcessRegistration[] registrations = _processes.Values.ToArray();
                _processes.Clear();
                foreach (ProcessRegistration process in registrations) process.Info.Process.DecrementReferenceCount();
            }
        }

        public void UpdateInput(List<GamepadInput> gamepadInputs)
        {
            foreach (GamepadInput input in gamepadInputs)
            {
                if (input.PlayerId is PlayerIndex.Player1 or PlayerIndex.Handheld)
                {
                    Volatile.Write(ref _pressedKeys, (long)input.Buttons);
                    return;
                }
            }
            Volatile.Write(ref _pressedKeys, 0);
        }
    }
}
