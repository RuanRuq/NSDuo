using System;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.Common.Logging
{
    public enum GraphicsTimingKind
    {
        RendererFrameWait,
        AcquireImage,
        QueueSubmitWithLock,
        QueueSubmitCall,
        QueuePresentWithLock,
        QueuePresentCall,
        GpuFenceWait,
        GpuSyncWait,
        GuestFrameFence,
        Count,
    }

    // A value-type scope retains its originating session's counter. It performs
    // no allocation, formatting or IO on the emulation/render threads.
    public readonly struct GraphicsTimingScope : IDisposable
    {
        private readonly DiagnosticTimingCounter _counter;
        private readonly long _started;

        internal GraphicsTimingScope(DiagnosticTimingCounter counter)
        {
            _counter = counter;
            counter.Begin();
            _started = Stopwatch.GetTimestamp();
        }

        public void Dispose()
        {
            _counter?.Complete(Stopwatch.GetTimestamp() - _started);
        }
    }

    internal sealed class DiagnosticTimingCounter
    {
        private long _calls;
        private long _totalTicks;
        private long _maxTicks;
        private long _over1Ms;
        private long _over16Ms;
        private int _active;

        internal void Begin() => Interlocked.Increment(ref _active);

        internal void Complete(long ticks)
        {
            ticks = Math.Max(0, ticks);
            Interlocked.Add(ref _totalTicks, ticks);
            if (ticks >= Stopwatch.Frequency / 1000) Interlocked.Increment(ref _over1Ms);
            if (ticks >= Stopwatch.Frequency * 16 / 1000) Interlocked.Increment(ref _over16Ms);

            long previous = Volatile.Read(ref _maxTicks);
            while (ticks > previous)
            {
                long observed = Interlocked.CompareExchange(ref _maxTicks, ticks, previous);
                if (observed == previous) break;
                previous = observed;
            }

            Interlocked.Increment(ref _calls);
            Interlocked.Decrement(ref _active);
        }

        // Counters are cumulative and sampled without blocking producers. A call
        // completing during a snapshot may appear partly in the next sample.
        internal (long Calls, long TotalTicks, long MaxTicks, long Over1Ms, long Over16Ms, int Active) Read()
            => (Volatile.Read(ref _calls), Volatile.Read(ref _totalTicks), Volatile.Read(ref _maxTicks),
                Volatile.Read(ref _over1Ms), Volatile.Read(ref _over16Ms), Volatile.Read(ref _active));
    }
}
