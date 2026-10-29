using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Ryujinx.Graphics.Vulkan;

namespace PipelineDriverChecks
{
    enum Result { Success, Error, Incomplete }
    enum StructureType { PipelineCacheCreateInfo }
    struct PipelineCache { public int Handle; }
    unsafe struct PipelineCacheCreateInfo { public StructureType SType; public nuint InitialDataSize; public void* PInitialData; }
    enum LogClass { Gpu }
    sealed class LogSink { public void PrintMsg(LogClass kind, string text) { } }
    static class Logger { public static LogSink Info = new(); public static LogSink Warning = new(); }
    static class ResultExtensions { public static void ThrowOnError(this Result result) { if (result != Result.Success) throw new InvalidOperationException(); } }
    sealed class PipelineHolder { public PipelineCache PipelineCache = new() { Handle = 1 }; }
    sealed class FakeCacheApi
    {
        public byte[] Data = [];
        public byte[] InitialData = [];
        public bool RejectInitial;
        public bool FailEmpty;
        public bool Incomplete;
        public int Creates;
        public int Reads;
        public unsafe Result CreatePipelineCache(int device, in PipelineCacheCreateInfo info, void* allocator, out PipelineCache cache)
        {
            Creates++;
            cache = default;
            if (info.InitialDataSize != 0)
            {
                InitialData = new ReadOnlySpan<byte>(info.PInitialData, (int)info.InitialDataSize).ToArray();
                if (RejectInitial) return Result.Error;
            }
            else if (FailEmpty) return Result.Error;
            cache.Handle = Creates;
            return Result.Success;
        }
        public unsafe Result GetPipelineCacheData(int device, PipelineCache cache, ref nuint size, void* target)
        {
            Reads++;
            if (target == null) { size = (nuint)Data.Length; return Result.Success; }
            if (Incomplete) return Result.Incomplete;
            Data.CopyTo(new Span<byte>(target, (int)size));
            size = (nuint)Data.Length;
            return Result.Success;
        }
    }
    sealed partial class Renderer
    {
        readonly int _device;
        readonly PipelineCacheStorage _pipelineCacheStorage;
        readonly PipelineHolder _pipeline = new();
        readonly object PipelineCreationLock = new();
        long _pipelineCompileCount = 1;
        long _pipelineCompileTicks;
        long _pipelineWaitTicks;
        public FakeCacheApi Api = new();
        public Renderer(PipelineCacheStorage storage) => _pipelineCacheStorage = storage;

        public static void Run(string path, byte[] data, byte[] uuid)
        {
            PipelineCacheStorage storage = new(path, 0x106b, 9, 100, uuid);
            var loaded = new Renderer(storage);
            loaded.CreatePipelineCache();
            if (!loaded.Api.InitialData.AsSpan().SequenceEqual(data)) throw new Exception("saved data not passed to driver");
            var rejected = new Renderer(storage);
            rejected.Api.RejectInitial = true;
            if (rejected.CreatePipelineCache().Handle != 2 || rejected.Api.Creates != 2) throw new Exception("driver rejection did not fall back to an empty cache");
            var fresh = new Renderer(null);
            fresh.CreatePipelineCache();
            if (fresh.Api.Creates != 1 || fresh.Api.InitialData.Length != 0) throw new Exception("disabled cache supplied initial data");
            rejected.Api.FailEmpty = true;
            bool failed = false;
            try { rejected.CreatePipelineCache(); } catch (InvalidOperationException) { failed = true; }
            if (!failed) throw new Exception("real device error was swallowed");
            byte[] next = (byte[])data.Clone(); next[^1] ^= 7;
            var saved = new Renderer(storage);
            saved.Api.Data = next;
            saved.SavePipelineCache();
            if (!storage.Load().AsSpan().SequenceEqual(next)) throw new Exception("complete driver snapshot was not saved");
            saved.Api.Data = data;
            saved.Api.Incomplete = true;
            saved.SavePipelineCache();
            if (!storage.Load().AsSpan().SequenceEqual(next)) throw new Exception("incomplete driver snapshot replaced valid data");
            saved.Api.Reads = 0;
            saved._pipelineCompileCount = 0;
            saved.SavePipelineCache();
            if (saved.Api.Reads != 0) throw new Exception("unchanged cache needlessly serialized");
            storage.Save(data);
            Console.WriteLine("PASS actual renderer cache load/save methods: restore, driver rejection fallback, real error propagation, incomplete snapshot protection");
        }
    }
}
