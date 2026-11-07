using Ryujinx.Common.Logging;
using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Kernel.Process;
using System.Collections.Generic;
using System.Runtime.CompilerServices;

namespace Ryujinx.HLE.HOS.Tamper
{
    class TamperedKProcess : ITamperedProcess
    {
        private readonly KProcess _process;

        public ProcessState State => _process.State;
        public bool IsPaused => _process.IsPaused;

        public bool TamperedCodeMemory { get; set; } = false;

        public TamperedKProcess(KProcess process)
        {
            _process = process;
        }

        private void AssertMemoryRegion<T>(ulong va) where T : unmanaged
        {
            ulong size = (ulong)Unsafe.SizeOf<T>();

            // TODO (Caian): This double check is workaround because CpuMemory.IsRangeMapped reports
            // some addresses as mapped even though they are not, i. e. 4 bytes from 0xffffffffffffff70.
            if (size > ulong.MaxValue - va || !_process.CpuMemory.IsMapped(va) || !_process.CpuMemory.IsRangeMapped(va, size))
            {
                throw new TamperExecutionException($"Unmapped memory access of {size} bytes at 0x{va:X16}");
            }
        }

        public T ReadMemory<T>(ulong va) where T : unmanaged
        {
            AssertMemoryRegion<T>(va);

            return _process.CpuMemory.Read<T>(va);
        }

        public void WriteMemory<T>(ulong va, T value) where T : unmanaged
        {
            AssertMemoryRegion<T>(va);
            ulong size = (ulong)Unsafe.SizeOf<T>();
            bool executable = TouchesExecutableMemory(va, size);
            if (executable && EqualityComparer<T>.Default.Equals(_process.CpuMemory.Read<T>(va), value))
            {
                // Constant patches run every tick. Avoid discarding translations when
                // the instruction bytes already match the requested patch.
                return;
            }

            _process.CpuMemory.Write(va, value);
            if (executable)
            {
                TamperedCodeMemory = true;
                // Use the same process-context path as debugger/breakpoint writes.
                _process.Context.InvalidateCacheRegion(va, size);
            }
        }

        private bool TouchesExecutableMemory(ulong address, ulong size)
        {
            ulong end = address + size;
            while (address < end)
            {
                KMemoryInfo info = _process.MemoryManager.QueryMemory(address);
                try
                {
                    if ((info.Permission & KMemoryPermission.Execute) != 0)
                    {
                        return true;
                    }

                    ulong regionEnd = info.Address + info.Size;
                    if (regionEnd <= address || regionEnd >= end)
                    {
                        return false;
                    }
                    address = regionEnd;
                }
                finally
                {
                    KMemoryInfo.Pool.Release(info);
                }
            }
            return false;
        }

        public void PauseProcess()
        {
            Logger.Warning?.Print(LogClass.TamperMachine, "Process pausing is not supported!");
        }

        public void ResumeProcess()
        {
            Logger.Warning?.Print(LogClass.TamperMachine, "Process resuming is not supported!");
        }
    }
}
