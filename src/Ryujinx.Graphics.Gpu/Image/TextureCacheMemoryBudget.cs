using System;
using System.Threading;

namespace Ryujinx.Graphics.Gpu.Image
{
    // Published by the platform thread; consumed only at texture-cache safe points.
    internal sealed class TextureCacheMemoryBudget
    {
        internal sealed record Sample(ulong AvailableBytes, int CacheCount, long Warnings);

        private readonly Lock _lock = new();
        private Sample _latest;
        private long _warnings;

        public Sample Latest => Volatile.Read(ref _latest);

        public void Publish(ulong availableBytes, bool warning, int cacheCount)
        {
            lock (_lock)
            {
                if (warning) _warnings++;
                Volatile.Write(ref _latest, new Sample(availableBytes, Math.Max(1, cacheCount), _warnings));
            }
        }
    }
}
