using System;
using System.Runtime.ExceptionServices;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading
{
    // All producer-side waits observe the same terminal backend failure. A wait
    // interval only checks for failure; it never grants permission to free live
    // GPU resources or pretends that an unfinished command completed.
    internal sealed class RendererFaultState
    {
        private ExceptionDispatchInfo _failure;
        public void Fail(Exception error) => Interlocked.CompareExchange(ref _failure, ExceptionDispatchInfo.Capture(error), null);
        public void ThrowIfFaulted() => Volatile.Read(ref _failure)?.Throw();

        public void Wait(WaitHandle signal)
        {
            ThrowIfFaulted();
            while (!signal.WaitOne(50)) ThrowIfFaulted();
            ThrowIfFaulted();
        }

        public void Wait(ManualResetEventSlim signal)
        {
            ThrowIfFaulted();
            while (!signal.Wait(50)) ThrowIfFaulted();
            ThrowIfFaulted();
        }
    }
}
