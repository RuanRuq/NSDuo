using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

// Test boundary: native pipeline creation is replaced by a counted driver call.
// The lock/recheck/publication blocks are extracted verbatim from PipelineState.cs.
enum Result { Success, Error }
struct Pipeline { public int Handle; }
struct CreateInfo { public int Unused; }
sealed class Auto<T> { public T Value; public Auto(T value) => Value = value; }
sealed class DisposablePipeline
{
    public Pipeline Handle;
    public DisposablePipeline(FakeApi api, int device, Pipeline handle) => Handle = handle;
}
sealed class FakeApi
{
    public int Calls;
    public bool Fail;
    public Action<int> OnCreate;
    public unsafe Result CreateComputePipelines(int device, int cache, int count, CreateInfo* info, void* allocator, Pipeline* result)
    {
        result->Handle = Interlocked.Increment(ref Calls);
        OnCreate?.Invoke(result->Handle);
        return Fail ? Result.Error : Result.Success;
    }
    public unsafe Result CreateGraphicsPipelines(int device, int cache, int count, CreateInfo* info, void* allocator, Pipeline* result)
        => CreateComputePipelines(device, cache, count, info, allocator, result);
}
sealed class FakeRenderer
{
    public object PipelineCreationLock = new();
    public FakeApi Api = new();
    public void RecordPipelineCompile(long requested, long started, Result result) { }
}
sealed class FakeProgram
{
    public readonly object PipelineCreationLock = new();
    readonly Dictionary<int, Auto<DisposablePipeline>> _pipelines = new();
    public bool TryGetComputePipeline(ref int key, out Auto<DisposablePipeline> value)
    { lock (_pipelines) return _pipelines.TryGetValue(key, out value); }
    public bool TryGetGraphicsPipeline(ref int key, out Auto<DisposablePipeline> value) => TryGetComputePipeline(ref key, out value);
    public Auto<DisposablePipeline> AddComputePipeline(ref int key, Auto<DisposablePipeline> value)
    { lock (_pipelines) { if (_pipelines.TryGetValue(key, out var old)) return old; _pipelines.Add(key, value); return value; } }
    public Auto<DisposablePipeline> AddGraphicsPipeline(ref int key, Auto<DisposablePipeline> value) => AddComputePipeline(ref key, value);
}
static partial class PipelineConcurrencyChecks
{
    public static void Run()
    {
        foreach (var compile in new Func<FakeRenderer, FakeProgram, Barrier, int, Auto<DisposablePipeline>>[] { Compute, Graphics })
        {
            CheckIndependentPrograms(compile);
            FakeRenderer gd = new();
            FakeProgram program = new();
            using Barrier barrier = new(8);
            var tasks = new Task<Auto<DisposablePipeline>>[8];
            // Dedicated threads avoid thread pool starvation from the intentional barrier.
            for (int i = 0; i < tasks.Length; i++)
            {
                var done = new TaskCompletionSource<Auto<DisposablePipeline>>(TaskCreationOptions.RunContinuationsAsynchronously);
                tasks[i] = done.Task;
                new Thread(() => { try { done.SetResult(compile(gd, program, barrier, 7)); } catch (Exception e) { done.SetException(e); } }).Start();
            }
            if (!Task.WaitAll(tasks, 5000)) throw new Exception("concurrent pipeline requests deadlocked");
            if (gd.Api.Calls != 1) throw new Exception($"same pipeline compiled {gd.Api.Calls} times");
            foreach (var task in tasks) if (!ReferenceEquals(task.Result, tasks[0].Result)) throw new Exception("different cached pipeline published");
            using Barrier single = new(1);
            compile(gd, program, single, 8);
            if (gd.Api.Calls != 2) throw new Exception("different state must compile separately");
            // A transient background failure must not poison the cache or block a retry.
            gd.Api.Fail = true;
            compile(gd, program, single, 9);
            gd.Api.Fail = false;
            if (compile(gd, program, single, 9) == null || gd.Api.Calls != 4) throw new Exception("failed warm-up must remain retryable");
        }
        Console.WriteLine("PASS actual graphics/compute creation blocks: independent-program progress, concurrent deduplication, distinct state and failed warm-up retry");
    }

    static void CheckIndependentPrograms(Func<FakeRenderer, FakeProgram, Barrier, int, Auto<DisposablePipeline>> compile)
    {
        FakeRenderer gd = new();
        using ManualResetEventSlim backgroundEntered = new();
        using ManualResetEventSlim releaseBackground = new();
        using Barrier single = new(1);
        gd.Api.OnCreate = call =>
        {
            if (call != 1) return;
            backgroundEntered.Set();
            if (!releaseBackground.Wait(5000)) throw new Exception("background driver boundary timed out");
        };
        static Task<Auto<DisposablePipeline>> Start(Func<Auto<DisposablePipeline>> work)
        {
            var done = new TaskCompletionSource<Auto<DisposablePipeline>>(TaskCreationOptions.RunContinuationsAsynchronously);
            new Thread(() => { try { done.SetResult(work()); } catch (Exception e) { done.SetException(e); } }).Start();
            return done.Task;
        }
        var background = Start(() => compile(gd, new FakeProgram(), single, 1));
        Task<Auto<DisposablePipeline>> foreground = null;
        bool independentProgress = false;
        try
        {
            if (!backgroundEntered.Wait(3000)) throw new Exception("background never reached the driver");
            foreground = Start(() => compile(gd, new FakeProgram(), single, 2));
            // Foreground must finish while the unrelated background driver call is
            // still held, rather than merely finishing after it is released.
            independentProgress = foreground.Wait(1500);
        }
        finally
        {
            releaseBackground.Set();
            if (!background.Wait(3000) || (foreground != null && !foreground.Wait(3000)))
                throw new Exception("pipeline work did not finish after releasing the driver");
        }
        if (!independentProgress) throw new Exception("foreground pipeline blocked by an unrelated background program");
        if (foreground.Result == null || background.Result == null || gd.Api.Calls != 2)
            throw new Exception("independent work lost a pipeline");
    }
}
