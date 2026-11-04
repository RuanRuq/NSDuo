using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Vulkan;

static class GpuMemoryChecks
{
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    static void Main()
    {
        var cache = new AutoDeleteCache();
        var texture = new Texture { Size = 1 };
        cache.Add(texture);
        cache.AddShortCache(texture);
        Check(texture.ShortCacheEntry != null, "first overlap must enter the short cache");
        Check(texture.References == 2, "cache and short cache own one reference each");
        cache.AddShortCache(texture);
        Check(texture.References == 2, "repeated overlap must not duplicate ownership");
        cache.ProcessShortCache();
        Check(texture.References == 2, "first tick retains overlap");
        cache.ProcessShortCache();
        Check(texture.References == 0 && texture.CacheNode == null && texture.ShortCacheEntry == null,
            "second tick retires overlap and both references");
        cache.ProcessShortCache();
        Check(texture.References == 0, "expired entry cannot release twice");

        var reentrant = new Texture { Size = 1 };
        reentrant.OnZero = () => cache.RemoveShortCache(reentrant);
        cache.Add(reentrant);
        cache.AddShortCache(reentrant);
        cache.ProcessShortCache();
        cache.ProcessShortCache();
        Check(reentrant.References == 0 && reentrant.ShortCacheEntry == null,
            "destruction re-entry sees detached short-cache ownership");

        var descriptor = new TextureDescriptor(5);
        var pooled = new Texture { Size = 1 };
        cache.Add(pooled);
        cache.AddShortCache(pooled, ref descriptor);
        var entry = pooled.ShortCacheEntry;
        cache.AddShortCache(pooled);
        Check(ReferenceEquals(entry, pooled.ShortCacheEntry) && pooled.References == 2,
            "existing descriptor entry must keep its lookup and one reference");
        cache.RemoveShortCache(pooled);
        cache.ProcessShortCache();
        cache.ProcessShortCache();
        Check(pooled.References == 1 && cache.FindShortCache(in descriptor) == null,
            "explicit short removal preserves ordinary-cache reference");
        Console.WriteLine("PASS texture short-cache first/repeat/expiry/descriptor ownership");

        var reused = new Texture { Size = 1 };
        cache.Add(reused);
        cache.AddShortCache(reused);
        cache.ProcessShortCache();
        cache.Lift(reused);
        cache.ProcessShortCache();
        Check(reused.References == 1 && reused.CacheNode != null && reused.ShortCacheEntry == null,
            "reused render target cancels pending overlap expiry");
        cache.AddShortCache(reused);
        cache.ProcessShortCache();
        cache.ProcessShortCache(reused);
        Check(reused.References == 2, "current presentation texture must survive cache tick");
        cache.ProcessShortCache();
        Check(reused.References == 0, "unprotected presentation texture expires later");

        const ulong MiB = 1024 * 1024;
        var pressureCache = new AutoDeleteCache();
        var textures = Enumerable.Range(0, 12).Select(_ => new Texture { Size = 64 * MiB }).ToArray();
        foreach (var item in textures) pressureCache.Add(item);
        // Fewer than the old 32-entry threshold, but 768 MiB retained.
        var memory = new TextureCacheMemoryBudget();
        pressureCache.ProcessMemoryPressure(memory.Latest, textures[0]);
        Check(textures.All(item => item.References == 1), "no platform sample preserves desktop policy");
        memory.Publish(0, true, 1);
        memory.Publish(0, false, 1); // A subsequent sample must not erase an unconsumed warning.
        Check(memory.Latest.Warnings == 1, "warning survives sample replacement");
        var sample = memory.Latest;
        pressureCache.ProcessMemoryPressure(sample, textures[0]);
        int released = textures.Count(item => item.References == 0);
        Check(released >= 1 && released <= 4 && textures[0].References == 1,
            "pressure retires a bounded batch while protecting the displayed texture");
        var field = typeof(AutoDeleteCache).GetField("_maxCacheMemoryUsage", BindingFlags.Instance | BindingFlags.NonPublic);
        ulong firstBudget = (ulong)field.GetValue(pressureCache);
        pressureCache.ProcessMemoryPressure(sample, textures[0]);
        Check((ulong)field.GetValue(pressureCache) == firstBudget, "one sample cannot ratchet the budget each frame");
        for (int tick = 0; tick < 12; tick++) pressureCache.ProcessMemoryPressure(sample, textures[0]);
        Check(textures.Where(item => item.References > 0).Aggregate(0UL, (sum, item) => sum + item.Size) <= firstBudget,
            "bounded ticks eventually meet byte budget even below 32 textures");
        memory.Publish(8UL << 30, false, 1);
        pressureCache.ProcessMemoryPressure(memory.Latest, textures[0]);
        Check((ulong)field.GetValue(pressureCache) <= firstBudget, "warning budget cannot refill immediately after a healthy sample");
        Check((ulong)field.GetValue(pressureCache) <= firstBudget + 64 * MiB, "healthy samples restore budget gradually");
        var shared = new AutoDeleteCache();
        memory.Publish(ulong.MaxValue, false, 2);
        shared.ProcessMemoryPressure(memory.Latest, null);
        Check((ulong)field.GetValue(shared) <= 512 * MiB, "mobile budget is shared across texture caches without overflow");
        var roomy = new AutoDeleteCache();
        roomy.Initialize(new Ryujinx.Graphics.Gpu.GpuContext(), 12UL << 30);
        var roomyMemory = new TextureCacheMemoryBudget();
        roomyMemory.Publish(8UL << 30, false, 1);
        roomy.ProcessMemoryPressure(roomyMemory.Latest, null);
        Check((ulong)field.GetValue(roomy) > (1UL << 30) && (ulong)field.GetValue(roomy) <= (4UL << 30),
            "ample process headroom preserves the configured device budget without a fixed 1 GiB cap");

        var reentrantCache = new AutoDeleteCache();
        var neighbors = Enumerable.Range(0, 4).Select(_ => new Texture { Size = 64 * MiB }).ToArray();
        foreach (var item in neighbors)
        {
            item.Group.CanEvictWithoutGpuWork = false;
            reentrantCache.Add(item);
        }
        neighbors[0].SkipFlush = false;
        neighbors[0].OnFlush = () => reentrantCache.Remove(neighbors[1], false);
        memory.Publish(0, true, 1);
        for (int tick = 0; tick < 5; tick++) reentrantCache.ProcessMemoryPressure(memory.Latest, neighbors[3]);
        Check(neighbors[0].References == 0 && neighbors[1].References == 0 && neighbors[2].References == 0 && neighbors[3].References == 1,
            "eviction reloads its cursor after a flush removes the next cached texture");
        Console.WriteLine("PASS memory pressure snapshots/bounded trim/presentation protection/recovery");

        var idleCache = new AutoDeleteCache();
        var idleTextures = Enumerable.Range(0, 6).Select(_ => new Texture { Size = 64 * MiB }).ToArray();
        foreach (var item in idleTextures)
        {
            item.SkipFlush = false;
            item.OnFlush = () => throw new Exception("idle trim must never read back from the GPU");
            idleCache.Add(item);
        }
        idleTextures[0].Group.CanEvictWithoutGpuWork = false;
        idleTextures[1].IncrementReferenceCount(); // Bound/pool-owned texture.
        var idleBudget = new TextureCacheMemoryBudget();
        idleBudget.Publish(0, true, 1);
        for (int tick = 0; tick < 6; tick++)
            idleCache.ProcessMemoryPressure(idleBudget.Latest, idleTextures[2], allowGpuWork: false);
        Check(idleTextures[0].References == 1 && idleTextures[1].References == 2 && idleTextures[2].References == 1,
            "paused trim preserves GPU-owned data, active references and the displayed image");
        Check(idleTextures.Skip(3).All(item => item.References == 0), "paused trim releases clean cache-only textures without a new frame");

        using var scheduler = new BackgroundCompilationScheduler();
        using var gate = new ManualResetEventSlim(false);
        using var entered = new ManualResetEventSlim(false);
        int active = 0, peak = 0;
        Task[] work = Enumerable.Range(0, 10).Select(_ => scheduler.SchedulePipelineCompile(() =>
        {
            int count = Interlocked.Increment(ref active);
            Interlocked.Exchange(ref peak, Math.Max(peak, count));
            entered.Set();
            if (!gate.Wait(5000)) throw new Exception("pipeline worker timed out");
            Interlocked.Decrement(ref active);
        })).ToArray();
        Check(entered.Wait(3000), "pipeline worker starts");
        Check(active == 1, "pipeline compile concurrency is bounded");
        gate.Set();
        Check(Task.WaitAll(work, 5000) && peak == 1, "all queued compilations finish without overlap");
        Console.WriteLine("PASS bounded production compilation scheduler");

        using var shaderGate = new ManualResetEventSlim(false);
        using var shaderEntered = new ManualResetEventSlim(false);
        int shaderActive = 0, shaderPeak = 0;
        Task[] shaders = Enumerable.Range(0, 20).Select(_ => scheduler.ScheduleShaderCompile(() =>
        {
            int count = Interlocked.Increment(ref shaderActive);
            int previous;
            do { previous = Volatile.Read(ref shaderPeak); }
            while (count > previous && Interlocked.CompareExchange(ref shaderPeak, count, previous) != previous);
            shaderEntered.Set();
            if (!shaderGate.Wait(5000)) throw new Exception("shader worker timed out");
            Interlocked.Decrement(ref shaderActive);
        })).ToArray();
        Check(shaderEntered.Wait(3000), "shader worker starts");
        shaderGate.Set();
        Check(Task.WaitAll(shaders, 5000) && shaderPeak <= 2, "shader stages use at most two workers");
        Console.WriteLine("PASS bounded shader stages complete all requests");
        ShaderSchedulingChecks.Checks.Run();
    }
}

namespace Ryujinx.Common.Logging
{
    enum LogClass { Gpu }
    static class Logger { public static Sink Info => null; }
    sealed class Sink { public void Print(LogClass kind, string text) {} }
}
namespace Ryujinx.Graphics.Gpu
{
    class GpuContext { public DeviceCapabilities Capabilities = new(); }
    class DeviceCapabilities { public ulong MaximumGpuMemory = 8UL << 30; }
}
namespace Ryujinx.Graphics.Gpu.Image
{
    readonly record struct TextureDescriptor(int Value);
    sealed class Texture
    {
        public ulong Size;
        public int References;
        public int InvalidatedSequence = 0;
        public Action OnZero;
        public Action OnFlush;
        public bool SkipFlush = true;
        public LinkedListNode<Texture> CacheNode;
        public ShortTextureCacheEntry ShortCacheEntry;
        public TextureGroup Group = new();
        public void IncrementReferenceCount() => References++;
        public bool HasOneReference() => References == 1;
        public bool DecrementReferenceCount()
        {
            if (--References < 0) throw new Exception("reference underflow");
            if (References == 0) OnZero?.Invoke();
            return References == 0;
        }
        public bool CheckModified(bool value) => SkipFlush;
        public void FlushModified(bool value) => OnFlush?.Invoke();
    }
    sealed class TextureGroup
    {
        public bool CanEvictWithoutGpuWork = true;
        public void SynchronizeDependents(Texture texture) {}
    }
}
