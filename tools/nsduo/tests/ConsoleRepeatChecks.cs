using System;
using System.Collections.Concurrent;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Logging.Targets;

class Checks
{
    static void Assert(bool value) { if (!value) throw new Exception("Console repeat behavior failed"); }
    static LogEventArgs Entry(double time, LogLevel level = LogLevel.Info, string text = "repeat", object data = null)
        => new(level, TimeSpan.FromSeconds(time), "thread", text, data);
    static void Main()
    {
        var filter = new ConsoleRepeatFilter();
        Assert(filter.Accept(Entry(0), out int skipped) && skipped == 0);
        Assert(!filter.Accept(Entry(0.1), out skipped));
        Assert(!filter.Accept(Entry(0.2), out skipped));
        Assert(filter.Accept(Entry(1), out skipped) && skipped == 2);
        Assert(!filter.Accept(Entry(1.1), out skipped));
        Assert(filter.Accept(Entry(1.2, LogLevel.Error), out skipped) && skipped == 1);
        Assert(filter.Accept(Entry(1.3, LogLevel.Error), out skipped));
        Assert(filter.Accept(Entry(1.4, LogLevel.Warning), out skipped));
        Assert(filter.Accept(Entry(1.5, LogLevel.Warning), out skipped));
        Assert(filter.Accept(Entry(2, data: new object()), out skipped));
        Assert(filter.Accept(Entry(2.1, data: new object()), out skipped));
        Assert(filter.Accept(Entry(0), out skipped));
        Assert(filter.Accept(Entry(-1), out skipped));
        Console.WriteLine("PASS: console repeat coalescing, periodic summaries, warnings/errors and structured data retained");
        CheckFlushWaitsForInflightLog();
        CheckFlushDuringDispose();
        CheckWriterReentry();
    }

    static void CheckFlushWaitsForInflightLog()
    {
        using var target = new BlockingTarget();
        using var wrapper = new AsyncLogTargetWrapper(target, 4);
        wrapper.Log(null, Entry(1, LogLevel.Error, "last error before restoring stdout"));
        Assert(target.Entered.Wait(3000));
        using var flushEntered = new ManualResetEventSlim(false);
        Task flush = Task.Run(() => { flushEntered.Set(); wrapper.Flush(); });
        Assert(flushEntered.Wait(3000));
        bool returnedBeforeWrite = flush.Wait(150);
        target.Release.Set();
        Assert(flush.Wait(3000));
        if (returnedBeforeWrite || target.Writes != 1)
            throw new Exception("Flush returned before the already-dequeued final error was written");
        Assert(Task.WaitAll([Task.Run(wrapper.Flush), Task.Run(wrapper.Flush)], 3000));
        Console.WriteLine("PASS: flush barrier drains an in-flight final error and supports repeated flushes");
    }

    static void CheckFlushDuringDispose()
    {
        using var target = new BlockingTarget();
        var wrapper = new AsyncLogTargetWrapper(target, 4);
        wrapper.Log(null, Entry(1, LogLevel.Warning, "last warning during shutdown"));
        Assert(target.Entered.Wait(3000));
        Task dispose = Task.Run(wrapper.Dispose);
        var queue = (BlockingCollection<LogEventArgs>)typeof(AsyncLogTargetWrapper)
            .GetField("_messageQueue", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(wrapper);
        Assert(SpinWait.SpinUntil(() => queue.IsAddingCompleted, 3000));
        Task flush = Task.Run(wrapper.Flush);
        bool returnedBeforeWrite = flush.Wait(150);
        target.Release.Set();
        Assert(Task.WaitAll([dispose, flush], 3000));
        Assert(!returnedBeforeWrite && target.Writes == 1);
        wrapper.Dispose();
        wrapper.Flush();
        Console.WriteLine("PASS: flush/dispose race drains pending output without double-dispose deadlock");
    }

    static void CheckWriterReentry()
    {
        using var completed = new ManualResetEventSlim(false);
        var target = new CallbackTarget();
        var wrapper = new AsyncLogTargetWrapper(target, 4);
        target.Action = () => { wrapper.Flush(); wrapper.Dispose(); completed.Set(); };
        wrapper.Log(null, Entry(1));
        if (!completed.Wait(3000)) throw new Exception("console writer deadlocked on reentrant flush/dispose");
        wrapper.Dispose();
        Console.WriteLine("PASS: writer-thread flush and disposal do not self-wait");
    }

    sealed class BlockingTarget : ILogTarget
    {
        public ManualResetEventSlim Entered = new(false), Release = new(false);
        public int Writes;
        public string Name => "blocking-console";
        public void Log(object sender, LogEventArgs args)
        {
            Entered.Set();
            if (!Release.Wait(5000)) throw new Exception("test console target remained blocked");
            Interlocked.Increment(ref Writes);
        }
        public void Dispose() { Release.Set(); Entered.Dispose(); Release.Dispose(); }
    }
    sealed class CallbackTarget : ILogTarget
    {
        public Action Action;
        public string Name => "callback-console";
        public void Log(object sender, LogEventArgs args) => Action();
        public void Dispose() {}
    }
}
