using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Backends.SDL3;
using Ryujinx.Audio.Common;
using SDL;

static class AudioHooks
{
    public static Action AfterPcmWritten;
    public static Action CallbackEntered;
}

static class AudioChecks
{
    static int failures;
    static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    static void Run(string name, Action test)
    {
        try { test(); Console.WriteLine("PASS " + name); }
        catch (Exception error) { failures++; Console.WriteLine("FAIL " + name + ": " + error.Message); }
        finally { AudioHooks.AfterPcmWritten = null; AudioHooks.CallbackEntered = null; }
    }

    static AudioBuffer Buffer(byte[] data, ulong tag = 1) => new()
    {
        Data = data, DataPointer = tag, DataSize = (ulong)data.Length,
    };

    static SDL3HardwareDeviceSession Session(SDL3HardwareDeviceDriver driver, SampleFormat format = SampleFormat.PcmInt16, uint channels = 2)
        => new(driver, null, format, 48000, channels);

    static void PublicationRace()
    {
        using var written = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        using var entered = new ManualResetEventSlim();
        using var driver = new SDL3HardwareDeviceDriver();
        using var session = Session(driver);
        var buffer = Buffer(Enumerable.Range(0, 960).Select(x => (byte)x).ToArray());
        session.Start();
        AudioHooks.AfterPcmWritten = () => { written.Set(); Check(release.Wait(3000), "publisher release timeout"); };
        AudioHooks.CallbackEntered = entered.Set;
        var producer = Task.Run(() => session.QueueBuffer(buffer));
        Task consumer = null;
        try
        {
            Check(written.Wait(3000), "publisher did not reach PCM boundary");
            consumer = Task.Run(() => driver.Pull(buffer.Data.Length));
            Check(entered.Wait(3000), "callback not entered");
            // Old code finishes here before metadata exists. Correct code waits
            // for the transaction, without needing any SDL lock on the producer.
            consumer.Wait(300);
        }
        finally { release.Set(); }
        Check(producer.Wait(3000) && consumer != null && consumer.Wait(3000), "publication/callback deadlock");
        Check(session.GetPlayedSampleCount() == 240, "PCM was consumed without accounting its 240 frames");
        Check(session.WasBufferFullyConsumed(buffer), "consumed buffer remains queued");
        Check(driver.Updated.WaitOne(0), "completion notification missing");
        Check(SDL3.LastOutput.SequenceEqual(buffer.Data), "publication changed PCM");
    }

    static void FullVolume()
    {
        foreach (SampleFormat format in new[] { SampleFormat.PcmInt8, SampleFormat.PcmInt16, SampleFormat.PcmInt32, SampleFormat.PcmFloat })
        {
            using var driver = new SDL3HardwareDeviceDriver();
            using var session = Session(driver, format);
            int frameBytes = BackendHelper.GetSampleSize(format) * 2;
            var buffer = Buffer(Enumerable.Range(0, frameBytes * 7).Select(x => (byte)(x * 13)).ToArray());
            session.Start(); session.QueueBuffer(buffer);
            SDL3.MixCalls = 0; MemoryHooks.SpanRents = 0;
            driver.Pull(frameBytes * 10);
            Check(SDL3.LastOutput.Take(buffer.Data.Length).SequenceEqual(buffer.Data), "full-volume PCM differs for " + format);
            Check(SDL3.LastOutput.Skip(buffer.Data.Length).All(x => x == 0), "underrun tail is not silent");
            Check(session.GetPlayedSampleCount() == 7, "silence counted as played frames");
            bool floatFormat = format == SampleFormat.PcmFloat;
            Check(SDL3.MixCalls == (floatFormat ? 1 : 0), "unit-gain mixing path differs for " + format);
            Check(MemoryHooks.SpanRents == (floatFormat ? 2 : 1), "unexpected sample rental count for " + format);
        }
    }

    static void PartialMuteAndAccounting()
    {
        using var driver = new SDL3HardwareDeviceDriver { Volume = 0.5f };
        using var session = Session(driver, SampleFormat.PcmInt16, 1);
        var samples = new short[] { 1000, -1000, 2000, -2000, 3000, -3000 };
        var bytes = MemoryMarshal.AsBytes(samples.AsSpan()).ToArray();
        var first = Buffer(bytes[..8], 10);
        var second = Buffer(bytes[8..], 11);
        session.SetVolume(0.5f); session.Start(); session.QueueBuffer(first); session.QueueBuffer(second);
        SDL3.MixCalls = 0;
        driver.Pull(6);
        Check(MemoryMarshal.Cast<byte, short>(SDL3.LastOutput).SequenceEqual(new short[] { 250, -250, 500 }), "combined partial volume differs");
        Check(SDL3.MixCalls == 1 && session.GetPlayedSampleCount() == 3, "partial mixing/count wrong");
        Check(!session.WasBufferFullyConsumed(first) && !driver.Updated.WaitOne(0), "partial buffer marked complete");
        session.SetVolume(0);
        driver.Pull(10);
        Check(SDL3.LastOutput.All(x => x == 0), "mute is not silent");
        Check(session.GetPlayedSampleCount() == 6 && session.WasBufferFullyConsumed(second), "mute failed to consume/account buffers");
        Check(driver.Updated.WaitOne(0), "cross-buffer completion did not notify");
        driver.Updated.Reset(); driver.Pull(8);
        Check(session.GetPlayedSampleCount() == 6 && !driver.Updated.WaitOne(0), "underrun manufactured progress");
    }

    static void PauseResumeAndClose()
    {
        using var driver = new SDL3HardwareDeviceDriver();
        var session = Session(driver);
        var buffer = Buffer(new byte[960]);
        session.QueueBuffer(buffer); driver.Pull(960);
        Check(session.GetPlayedSampleCount() == 0, "unstarted stream consumed PCM");
        session.Start(); driver.Pull(480); session.Stop(); driver.Pull(480);
        Check(session.GetPlayedSampleCount() == 120, "paused stream consumed PCM");
        session.Start(); driver.Pull(480);
        Check(session.GetPlayedSampleCount() == 240, "resume lost queued PCM");
        session.Dispose(); driver.Pull(480);
        Check(driver.Destroyed, "close did not destroy stream");
    }

    static int Main()
    {
        Run("atomic PCM/metadata publication under callback interleaving", PublicationRace);
        Run("unit gain: signed integer direct read, float SDL path, silent underrun", FullVolume);
        Run("partial/mute volume, partial/cross-buffer completion and underrun", PartialMuteAndAccounting);
        Run("start/pause/resume/close lifecycle", PauseResumeAndClose);
        return failures == 0 ? 0 : 1;
    }
}

// Native SDL/driver boundaries are substitutes. Session, ring, sample counting
// and pooled buffers are production source; no audio device is opened on the host.
static class MemoryHooks { public static int SpanRents; }
namespace Ryujinx.Common
{
    static class BitUtils { public static int AlignUp(int value, int alignment) => (value + alignment - 1) & -alignment; }
}
namespace Ryujinx.Common.Logging
{
    enum LogClass { Audio }
    sealed class Sink { public void Print(LogClass kind, string text) { } }
    static class Logger { public static Sink Info => null; }
}
namespace Ryujinx.Memory { public interface IVirtualMemoryManager { void Read(ulong address, Span<byte> data); } }
namespace Ryujinx.Audio { static class Constants { public const uint TargetSampleCount = 240; } }
namespace Ryujinx.Audio.Backends.SDL3
{
    sealed unsafe class SDL3HardwareDeviceDriver : IDisposable
    {
        public static SDL3HardwareDeviceDriver Current;
        internal SDL3HardwareDeviceSession.SDL_AudioStreamCallback Callback;
        public ManualResetEvent Updated = new(false);
        public float Volume = 1;
        public bool Paused = true, Destroyed;
        public SDL3HardwareDeviceDriver() { Current = this; }
        public ManualResetEvent GetUpdateRequiredEvent() => Updated;
        public static SDL_AudioFormat GetSDL3Format(SampleFormat format) => (SDL_AudioFormat)format;
        public static SDL_AudioStream* OpenStream(SampleFormat format, uint rate, uint channels, uint count, SDL3HardwareDeviceSession.SDL_AudioStreamCallback callback)
        { Current.Callback = callback; return (SDL_AudioStream*)1; }
        public bool Unregister(SDL3HardwareDeviceSession session) => !Destroyed;
        public void Pull(int size) { if (!Paused && !Destroyed) Callback(0, (SDL_AudioStream*)1, size, size); }
        public void Dispose() => Updated.Dispose();
    }
}
namespace SDL
{
    struct SDL_AudioStream { }
    enum SDL_AudioFormat { }
    static unsafe class SDL3
    {
        public static byte[] LastOutput;
        public static int MixCalls;
        public static void SDL_ResumeAudioStreamDevice(SDL_AudioStream* stream) => SDL3HardwareDeviceDriver.Current.Paused = false;
        public static void SDL_PauseAudioStreamDevice(SDL_AudioStream* stream) => SDL3HardwareDeviceDriver.Current.Paused = true;
        public static void SDL_DestroyAudioStream(SDL_AudioStream* stream) => SDL3HardwareDeviceDriver.Current.Destroyed = true;
        public static void SDL_PutAudioStreamData(SDL_AudioStream* stream, nint data, int size) => LastOutput = new ReadOnlySpan<byte>((void*)data, size).ToArray();
        public static void SDL_MixAudio(byte* destination, byte* source, SDL_AudioFormat format, uint size, float volume)
        {
            MixCalls++;
            var src = new ReadOnlySpan<byte>(source, (int)size); var dst = new Span<byte>(destination, (int)size);
            if (volume == 1) { src.CopyTo(dst); return; }
            if ((SampleFormat)format != SampleFormat.PcmInt16) throw new Exception("test mixer only scales PCM16");
            var samples = MemoryMarshal.Cast<byte, short>(src); var output = MemoryMarshal.Cast<byte, short>(dst);
            for (int i = 0; i < samples.Length; i++) output[i] = (short)Math.Clamp((int)(samples[i] * volume), short.MinValue, short.MaxValue);
        }
    }
}
