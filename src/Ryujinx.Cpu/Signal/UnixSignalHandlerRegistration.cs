using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Cpu.Signal
{
    static partial class UnixSignalHandlerRegistration
    {
        internal const int DarwinSigInfo = 0x40;
        internal const int LinuxSigInfo = 4;

        // Darwin's sigset_t is 32 bits. Its flags follow at byte 12, while
        // Linux uses a 128-byte sigset_t and flags at byte 136 on 64-bit hosts.
        [StructLayout(LayoutKind.Sequential)]
        internal struct DarwinSigAction
        {
            public nint Handler;
            public uint Mask;
            public int Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal unsafe struct LinuxSigSet
        {
            public fixed ulong Bits[16];
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct LinuxSigAction
        {
            public nint Handler;
            public LinuxSigSet Mask;
            public int Flags;
            public nint Restorer;
        }

        internal readonly struct SigAction
        {
            internal readonly DarwinSigAction Darwin;
            internal readonly LinuxSigAction Linux;
            public nint Handler { get; }
            public bool UsesSigInfo { get; }

            internal SigAction(DarwinSigAction action)
            {
                Darwin = action;
                Linux = default;
                Handler = action.Handler;
                UsesSigInfo = (action.Flags & DarwinSigInfo) != 0;
            }

            internal SigAction(LinuxSigAction action)
            {
                Darwin = default;
                Linux = action;
                Handler = action.Handler;
                UsesSigInfo = (action.Flags & LinuxSigInfo) != 0;
            }
        }

        internal readonly struct SignalHandlers
        {
            public SigAction SegmentationFault { get; }
            public SigAction BusError { get; }
            public bool HasBusError { get; }

            internal SignalHandlers(SigAction segmentationFault, SigAction busError, bool hasBusError)
            {
                SegmentationFault = segmentationFault;
                BusError = busError;
                HasBusError = hasBusError;
            }
        }

        private const int SIGSEGV = 11;
        private const int SIGBUS = 10; // Registered only on Darwin.
        private static bool IsDarwin => OperatingSystem.IsMacOS() || OperatingSystem.IsIOS();

        [LibraryImport("libc", EntryPoint = "sigaction", SetLastError = true)]
        private static partial int DarwinSigaction(int signal, ref DarwinSigAction action, out DarwinSigAction old);

        [LibraryImport("libc", EntryPoint = "sigaction", SetLastError = true)]
        private static partial int DarwinSigaction(int signal, nint action, out DarwinSigAction old);

        [LibraryImport("libc", EntryPoint = "sigaction", SetLastError = true)]
        private static partial int LinuxSigaction(int signal, ref LinuxSigAction action, out LinuxSigAction old);

        [LibraryImport("libc", EntryPoint = "sigaction", SetLastError = true)]
        private static partial int LinuxSigaction(int signal, nint action, out LinuxSigAction old);

        private static SigAction GetAction(int signal)
        {
            if (IsDarwin)
            {
                if (DarwinSigaction(signal, nint.Zero, out DarwinSigAction old) == 0)
                {
                    return new SigAction(old);
                }
            }
            else
            {
                if (LinuxSigaction(signal, nint.Zero, out LinuxSigAction old) == 0)
                {
                    return new SigAction(old);
                }
            }

            throw new InvalidOperationException($"Could not read signal {signal} action. Error: {Marshal.GetLastPInvokeError()}");
        }

        private static bool SetAction(int signal, SigAction action)
        {
            if (IsDarwin)
            {
                DarwinSigAction native = action.Darwin;
                return DarwinSigaction(signal, ref native, out _) == 0;
            }

            LinuxSigAction linux = action.Linux;
            return LinuxSigaction(signal, ref linux, out _) == 0;
        }

        public static SigAction GetSegfaultExceptionHandler() => GetAction(SIGSEGV);

        public static void RegisterExceptionHandler(nint action, Action<SignalHandlers> beforeInstall)
        {
            SignalHandlers previous = new(GetAction(SIGSEGV), IsDarwin ? GetAction(SIGBUS) : default, IsDarwin);
            // Publish the previous handlers before the new native callback can
            // run on another thread, including during partial installation.
            beforeInstall(previous);

            SigAction current = IsDarwin
                ? new SigAction(new DarwinSigAction { Handler = action, Flags = DarwinSigInfo })
                : new SigAction(new LinuxSigAction { Handler = action, Flags = LinuxSigInfo });

            if (!SetAction(SIGSEGV, current))
            {
                throw new InvalidOperationException($"Could not register SIGSEGV action. Error: {Marshal.GetLastPInvokeError()}");
            }

            if (previous.HasBusError && !SetAction(SIGBUS, current))
            {
                int error = Marshal.GetLastPInvokeError();
                SetAction(SIGSEGV, previous.SegmentationFault);
                throw new InvalidOperationException($"Could not register SIGBUS action. Error: {error}");
            }
        }

        public static bool RestoreExceptionHandler(SignalHandlers previous)
        {
            bool restored = SetAction(SIGSEGV, previous.SegmentationFault);
            if (previous.HasBusError)
            {
                restored &= SetAction(SIGBUS, previous.BusError);
            }
            return restored;
        }
    }
}
