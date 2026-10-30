using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Cpu.LightningJit;
using Ryujinx.Cpu.LightningJit.State;

static class JitSharingChecks
{
    static int failures;
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Run(string name, Action test)
    {
        try { test(); Console.WriteLine("PASS " + name); }
        catch (Exception error) { failures++; Console.WriteLine("FAIL " + name + ": " + error.Message); }
    }
    static byte[] Compile(Translator translator, ulong address = 1, ExecutionMode mode = ExecutionMode.Aarch64)
        => translator.Invoke(address, mode).Code.ToArray();
    static void Join(params Task[] tasks) => Check(Task.WaitAll(tasks, 4000), "worker timeout/deadlock");

    static void SameKeyAndIsolation()
    {
        var translator = new Translator();
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        int calls = 0;
        Translator.Hook = (address, mode) => {
            Interlocked.Increment(ref calls);
            if (address == 1 && mode == ExecutionMode.Aarch64) { entered.Set(); Check(release.Wait(4000), "release timeout"); }
            return new CompiledFunction(new byte[] { (byte)address, (byte)mode }, 4);
        };
        var owner = Task.Run(() => Compile(translator));
        Check(entered.Wait(2000), "owner did not start");
        var waiter = Task.Run(() => Compile(translator));
        bool merged = SpinWait.SpinUntil(() => translator.Merged == 1 || Volatile.Read(ref calls) >= 2, 2000);
        var differentAddress = Task.Run(() => Compile(translator, 2));
        var differentMode = Task.Run(() => Compile(translator, 1, ExecutionMode.Aarch32Thumb));
        bool independent = Task.WaitAll(new Task[] { differentAddress, differentMode }, 2000);
        release.Set(); Join(owner, waiter, differentAddress, differentMode);
        Check(merged && independent, "unrelated address/mode compilation blocked");
        Check(calls == 3 && translator.Merged == 1, "same address/mode compiled more than once");
        Check(owner.Result.SequenceEqual(waiter.Result) && translator.Copies == 1, "shared code copy missing/wrong");
        // Simulated callers receive code bytes; no mapping or thread frame pointer is shared.
        Compile(translator, 2);
        Check(calls == 4 && translator.Copies == 1, "completed code retained or uncontended compile copied");
        translator.Close();
    }

    static void FailureRetry()
    {
        var translator = new Translator();
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        int calls = 0;
        Translator.Hook = (_, _) => { int count = Interlocked.Increment(ref calls); if (count == 1) { entered.Set(); release.Wait(3000); throw new InvalidOperationException("synthetic compile failure"); } return new(new byte[] { 9 }, 4); };
        bool Invoke() { try { Compile(translator); return false; } catch (InvalidOperationException) { return true; } }
        var owner = Task.Run(Invoke); Check(entered.Wait(2000), "owner did not start"); var waiter = Task.Run(Invoke);
        SpinWait.SpinUntil(() => translator.Merged == 1 || Volatile.Read(ref calls) >= 2, 2000);
        release.Set(); Join(owner, waiter);
        Check(owner.Result && waiter.Result && calls == 1, "failure not shared by current waiters");
        Check(Compile(translator)[0] == 9 && calls == 2, "failed entry poisoned retry"); translator.Close();
    }

    static void Invalidation()
    {
        var translator = new Translator();
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        int version = 1, calls = 0;
        Translator.Hook = (_, _) => { Interlocked.Increment(ref calls); int snapshot = Volatile.Read(ref version); if (snapshot == 1) { entered.Set(); release.Wait(4000); } return new(new byte[] { (byte)snapshot }, 4); };
        var owner = Task.Run(() => Compile(translator)); Check(entered.Wait(2000), "owner not started"); var waiter = Task.Run(() => Compile(translator));
        SpinWait.SpinUntil(() => translator.Merged == 1 || Volatile.Read(ref calls) >= 2, 2000);
        Volatile.Write(ref version, 2); translator.Invalidate();
        var fresh = Task.Run(() => Compile(translator)); bool progressed = fresh.Wait(2000);
        release.Set(); Join(owner, waiter, fresh);
        Check(progressed && new[] { owner.Result, waiter.Result, fresh.Result }.All(code => code[0] == 2), "old-generation code reused after invalidation");
        Check(translator.Retries >= 1, "invalidated retries not counted"); translator.Close();
    }

    static void ReentrantAndDispose()
    {
        var translator = new Translator(); int depth = 0;
        Translator.Hook = (_, _) => { if (depth++ == 0) { try { return new CompiledFunction(Compile(translator), 4); } finally { depth--; } } depth--; return new(new byte[] { 7 }, 4); };
        var reentrant = Task.Run(() => Compile(translator)); Check(reentrant.Wait(2000) && reentrant.Result[0] == 7, "same-thread compile waited on itself");
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        Translator.Hook = (_, _) => { entered.Set(); release.Wait(4000); return new(new byte[] { 1 }, 4); };
        bool Invoke() { try { Compile(translator, 2); return false; } catch (ObjectDisposedException) { return true; } }
        var owner = Task.Run(Invoke); Check(entered.Wait(2000), "owner not started"); var waiter = Task.Run(Invoke);
        SpinWait.SpinUntil(() => translator.Merged == 1, 1000); translator.Close();
        bool waiterReleased = waiter.Wait(1000); release.Set(); Join(owner, waiter);
        Check(waiterReleased && owner.Result && waiter.Result, "dispose retained waiters or published late code");
    }

    static void IosCompilesIndependently()
    {
        Translator.PlatformIOS = true;
        var translator = new Translator();
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        int calls = 0;
        Translator.Hook = (address, mode) => {
            Check(address == 1 && mode == ExecutionMode.Aarch64, "compile inputs changed");
            int call = Interlocked.Increment(ref calls);
            if (call == 1) { entered.Set(); Check(release.Wait(4000), "owner release timeout"); }
            return new CompiledFunction(new byte[] { (byte)call }, call * 4);
        };
        (byte[] Code, int GuestCodeLength) Invoke()
        {
            CompiledFunction result = translator.Invoke(1, ExecutionMode.Aarch64);
            return (result.Code.ToArray(), result.GuestCodeLength);
        }
        var owner = Task.Run(Invoke);
        Task<(byte[] Code, int GuestCodeLength)> second = null;
        bool progressed = false;
        try
        {
            Check(entered.Wait(2000), "iOS owner did not start");
            second = Task.Run(Invoke);
            progressed = second.Wait(1500);
        }
        finally
        {
            release.Set();
            if (second != null) Join(owner, second); else Join(owner);
            Translator.PlatformIOS = false;
            translator.Close();
        }
        Check(progressed, "iOS same-key compilation waited for another thread");
        Check(calls == 2 && translator.Merged == 0 && translator.Copies == 0,
            "iOS compilation entered sharing coordinator");
        Check(owner.Result.Code[0] == 1 && owner.Result.GuestCodeLength == 4 &&
            second.Result.Code[0] == 2 && second.Result.GuestCodeLength == 8,
            "iOS callers did not receive their own compiled code and length");
    }

    static int Main()
    {
        Run("same key merges; different addresses/modes progress; no completed cache or uncontended copy", SameKeyAndIsolation);
        Run("compile failure shared then retryable", FailureRetry);
        Run("invalidation rejects old generation and permits fresh progress", Invalidation);
        Run("same-thread reentry and dispose release", ReentrantAndDispose);
        Run("iOS same-key calls compile independently while another thread is blocked", IosCompilesIndependently);
        return failures == 0 ? 0 : 1;
    }
}
