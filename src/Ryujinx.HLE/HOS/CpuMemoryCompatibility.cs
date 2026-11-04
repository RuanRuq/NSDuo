using Ryujinx.Common.Configuration;
using System;

namespace Ryujinx.HLE.HOS
{
    internal static class CpuMemoryCompatibility
    {
        internal static MemoryManagerMode Resolve(MemoryManagerMode requested, string titleId, bool isIosArm64)
        {
            // Galaxy 1.3.1 reaches a tagged/high-bit address during startup.
            // Keep LightningJit, using the checked host memory translation to
            // prevent those bits from indexing beyond the native page table.
            if (isIosArm64 && requested == MemoryManagerMode.HostMappedUnsafe &&
                string.Equals(titleId, "010099C022B96000", StringComparison.OrdinalIgnoreCase))
            {
                return MemoryManagerMode.HostMapped;
            }

            return requested;
        }
    }
}
