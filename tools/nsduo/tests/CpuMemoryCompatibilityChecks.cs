using Ryujinx.Common.Configuration;
using Ryujinx.HLE.HOS;
using System;

static class CpuMemoryCompatibilityChecks
{
    internal static void Run()
    {
        static void Check(bool condition) { if (!condition) throw new Exception("CPU memory compatibility regression"); }
        const string galaxy = "010099C022B96000";
        Check(CpuMemoryCompatibility.Resolve(MemoryManagerMode.HostMappedUnsafe, galaxy, true) == MemoryManagerMode.HostMapped);
        Check(CpuMemoryCompatibility.Resolve(MemoryManagerMode.HostMappedUnsafe, galaxy.ToLowerInvariant(), true) == MemoryManagerMode.HostMapped);
        Check(CpuMemoryCompatibility.Resolve(MemoryManagerMode.HostMappedUnsafe, galaxy, false) == MemoryManagerMode.HostMappedUnsafe);
        Check(CpuMemoryCompatibility.Resolve(MemoryManagerMode.HostMappedUnsafe, "0100000000000000", true) == MemoryManagerMode.HostMappedUnsafe);
        Check(CpuMemoryCompatibility.Resolve(MemoryManagerMode.HostMappedUnsafe, null, true) == MemoryManagerMode.HostMappedUnsafe);
        Check(CpuMemoryCompatibility.Resolve(MemoryManagerMode.SoftwarePageTable, galaxy, true) == MemoryManagerMode.SoftwarePageTable);
        Check(CpuMemoryCompatibility.Resolve(MemoryManagerMode.HostMapped, galaxy, true) == MemoryManagerMode.HostMapped);
    }
}
