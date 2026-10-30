using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Graphics.Vulkan;

namespace ShaderSchedulingChecks
{
    static class Checks
    {
        public static void Run()
        {
            using var renderer = new VulkanRenderer();
            Shader[] stages = Enumerable.Range(0, 24).Select(_ => Factory.Create(renderer, false)).ToArray();
            if (!renderer.Entered.Wait(3000)) throw new Exception("default shader path did not start");
            renderer.Gate.Set();
            if (!Task.WaitAll(stages.Select(stage => stage.CompileTask).ToArray(), 5000) || renderer.Peak > 2)
                throw new Exception("default shader creation bypassed bounded workers");
            if (stages.Any(stage => stage.CompileStatus != ProgramLinkStatus.Success))
                throw new Exception("default shader stages did not finish before use");
            Console.WriteLine("PASS actual default shader construction uses bounded scheduler");
        }
    }

    sealed class VulkanRenderer : IDisposable
    {
        public Vk Api = new();
        public BackgroundCompilationScheduler BackgroundCompilationScheduler = new();
        public ManualResetEventSlim Gate = new(false), Entered = new(false);
        public int Active, Peak;
        public void Dispose() { Gate.Set(); BackgroundCompilationScheduler.Dispose(); Gate.Dispose(); Entered.Dispose(); }
    }
    sealed class Vk {}
    struct Device {}
    enum ProgramLinkStatus { Incomplete, Success }
    sealed class ShaderSource { public Stage Stage = new(); }
    struct Stage { public int Convert() => 1; }
    partial class Shader
    {
        VulkanRenderer _gd;
        Vk _api;
        Device _device;
        int _stage;
        public ProgramLinkStatus CompileStatus;
        public readonly Task CompileTask;
        void Compile(ShaderSource source)
        {
            if (_gd == null) throw new Exception("default shader used an uncontrolled Task.Run constructor");
            int active = Interlocked.Increment(ref _gd.Active), previous;
            do { previous = Volatile.Read(ref _gd.Peak); }
            while (active > previous && Interlocked.CompareExchange(ref _gd.Peak, active, previous) != previous);
            _gd.Entered.Set();
            if (!_gd.Gate.Wait(5000)) throw new Exception("default shader timed out");
            Interlocked.Decrement(ref _gd.Active);
            CompileStatus = ProgramLinkStatus.Success;
        }
    }
}
