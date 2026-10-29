using System;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Common.Callbacks;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.Graphics.GAL.Multithreading.Resources;
using Ryujinx.Library;

partial class CoreChecks
{
    static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
    static void MustFail(Action action, string message)
    {
        try { action(); } catch { return; }
        throw new Exception(message);
    }
    static void Done(Task task, string message) { Check(task.Wait(3000), message); }

    static Task StartBackend(Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        new Thread(() => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } })
            { IsBackground = true, Name = "Test.RenderBackend" }.Start();
        return completion.Task;
    }

    static void RendererChecks()
    {
        var backend = DispatchProxy.Create<IRenderer, FakeRenderer>();
        var fake = (FakeRenderer)(object)backend;
        var renderer = new ThreadedRenderer(backend);
        var injected = new InvalidOperationException("injected backend command failure");
        Exception backendError = null, workerError = null, flushError = null;
        using var workerDone = new ManualResetEventSlim();
        var render = StartBackend(() => {
            try { renderer.RunLoop(() => {
                try { renderer.BackgroundContextAction(() => throw injected); }
                catch (Exception error) { workerError = error; }
                finally {
                    try { renderer.FlushThreadedCommands(); }
                    catch (Exception error) { flushError = error; }
                    workerDone.Set();
                }
            }); } catch (Exception error) { backendError = error; }
        });
        Check(workerDone.Wait(3000), "GPU worker hung after backend failure");
        Done(render, "backend failed to exit");
        Check(ReferenceEquals(workerError, injected) && ReferenceEquals(flushError, injected) && ReferenceEquals(backendError, injected),
            "all waiters must receive original render failure");
        MustFail(() => renderer.WaitForFrame(), "frame wait claimed success after failure");
        MustFail(() => renderer.CreateBuffer(16, BufferAccess.Default), "queue accepted work after failure");
        MustFail(() => fake.Interrupt(() => {}), "interrupt wait accepted failed backend");
        MustFail(renderer.Dispose, "renderer suppressed failure during disposal");
        Check(fake.Disposals == 1, "failed renderer did not dispose backend");
        renderer.Dispose(); Check(fake.Disposals == 1, "backend disposed twice");

        var fault = new RendererFaultState();
        using var sync = new SyncMap(fault);
        using var buffers = new BufferMap(fault);
        sync.CreateSyncHandle(42);
        var handle = buffers.CreateBufferHandle();
        var waits = new[] {
            Task.Run(() => MustFail(() => sync.WaitSyncAvailability(42), "sync succeeded")),
            Task.Run(() => MustFail(() => buffers.MapBufferBlocking(handle), "buffer succeeded"))
        };
        Thread.Sleep(30); fault.Fail(injected);
        foreach (var wait in waits) Done(wait, "pending resource waiter did not observe failure");

        // Backpressure and resource-creation spins also observe terminal failure.
        backend = DispatchProxy.Create<IRenderer, FakeRenderer>();
        var full = new ThreadedRenderer(backend);
        for (int i = 0; i < 9999; i++) full.CreateBuffer(16, BufferAccess.Default);
        var blockedProducer = Task.Run(() => MustFail(() => full.CreateBuffer(16, BufferAccess.Default), "full queue succeeded"));
        var gate = (RendererFaultState)typeof(ThreadedRenderer).GetField("_fault", BindingFlags.NonPublic|BindingFlags.Instance).GetValue(full);
        Thread.Sleep(30); gate.Fail(injected);
        Done(blockedProducer, "full queue spin ignored failure");
        var texture = new ThreadedTexture(full, default);
        MustFail(() => texture.GetData(), "texture creation spin ignored failure");
        full.Dispose();

        // Normal teardown must drain destruction commands before disposing backend.
        backend = DispatchProxy.Create<IRenderer, FakeRenderer>(); fake = (FakeRenderer)(object)backend;
        renderer = new ThreadedRenderer(backend);
        workerDone.Reset();
        render = StartBackend(() => renderer.RunLoop(() => workerDone.Set()));
        Check(workerDone.Wait(3000), "normal worker did not start");
        renderer.CreateBuffer(16, BufferAccess.Default);
        renderer.Dispose(); Done(render, "normal render loop did not stop");
        Check(fake.Creates == 1 && fake.Disposals == 1 && !fake.DisposedBeforeCreate, "teardown raced queued destruction");
        Console.WriteLine("PASS: real threaded renderer failure, invoke/frame/interrupt/queue/resource waits and ordered teardown");
    }

    public class FakeRenderer : DispatchProxy
    {
        public Action<Action> Interrupt;
        public int Disposals, Creates;
        public bool DisposedBeforeCreate;
        protected override object Invoke(MethodInfo method, object[] args)
        {
            switch (method.Name) {
                case "SetInterruptAction": Interrupt = (Action<Action>)args[0]; break;
                case "CreateBuffer": Thread.Sleep(15); Creates++; if (Disposals > 0) DisposedBeforeCreate = true; return BufferHandle.Null;
                case "Dispose": Disposals++; break;
            }
            return method.ReturnType == typeof(void) ? null : method.ReturnType.IsValueType ? Activator.CreateInstance(method.ReturnType) : null;
        }
    }

    static void WindowAndMotionChecks()
    {
        var renderer = new ThreadedRenderer(DispatchProxy.Create<IRenderer, FakeRenderer>());
        var beforeStart = new WindowRenderChecks { Run = () => throw new Exception("initialization failed") };
        beforeStart.Device.Gpu.Renderer = renderer; beforeStart.Render();
        Check(beforeStart._gpuDoneEvent.WaitOne(0), "initialization failure never signalled teardown");
        using var workerStarted = new ManualResetEventSlim();
        using var releaseWorker = new ManualResetEventSlim();
        var backend = StartBackend(() => renderer.RunLoop(() => { workerStarted.Set(); releaseWorker.Wait(); }));
        Check(workerStarted.Wait(3000), "worker did not start");
        var afterStart = new WindowRenderChecks { Run = () => throw new Exception("backend failed") };
        afterStart.Device.Gpu.Renderer = renderer; afterStart.Render();
        Check(!afterStart._gpuDoneEvent.WaitOne(0), "backend exception falsely reported live GPU worker done");
        releaseWorker.Set(); renderer.Dispose(); Done(backend, "teardown did not stop renderer");
        beforeStart._gpuDoneEvent.Dispose(); afterStart._gpuDoneEvent.Dispose();

        using var driver = new Ryujinx.Input.Native.NativeGamepadDriver();
        var id = Ryujinx.Input.Native.NativeGamepadDriver.AttachGamepad("test", (nint)1);
        int notifications = 0; Action observe = () => notifications++;
        Ryujinx.Input.Native.NativeGamepadDriver.OnInputUpdated += observe;
        try {
            Ryujinx.Input.Native.NativeGamepadDriver.SetMotionSample(id,1,2,3,4,5,6);
            Check(notifications == 1, "one motion sample woke input twice");
            Ryujinx.Input.Native.NativeGamepadDriver.SetMotionSample(id,1,2,3,4,5,6);
            Check(notifications == 1, "identical motion sample woke input again");
            var gamepad=driver.GetGamepad("1");
            Check(gamepad.GetMotionData(Ryujinx.Input.MotionInputId.Accelerometer) == new Vector3(1,2,3) &&
                  gamepad.GetMotionData(Ryujinx.Input.MotionInputId.Gyroscope) == new Vector3(4,5,6), "motion axes lost");
        } finally { Ryujinx.Input.Native.NativeGamepadDriver.OnInputUpdated -= observe; }
        Console.WriteLine("PASS: live GPU completion ownership and one wakeup per changed motion sample");
    }

    static unsafe void TouchChecks()
    {
        using var driver = new NativeTouchDriver(HideCursorMode.Never);
        delegate* unmanaged<float,float,int,void> begin = &NativeTouchDriver.TouchBeganAtPoint;
        delegate* unmanaged<float,float,int,void> move = &NativeTouchDriver.TouchMovedAtPoint;
        delegate* unmanaged<int,void> end = &NativeTouchDriver.TouchEndedForIndex;
        begin(10,20,0); begin(30,40,1); end(0); move(50,60,1);
        var points = driver.GetTouchPoints();
        Check(points.Length == 1 && points[0].Id == 1 && points[0].Position == new Vector2(50,60), "native touch ID changed");
        var writer = Task.Run(() => { for (int i=0;i<50000;i++) { begin(i,i,0); move(i+1,i+1,0); end(0); } });
        while (!writer.IsCompleted) {
            points = driver.GetTouchPoints();
            Check(points.Length <= 2 && points.Select(p=>p.Id).Distinct().Count() == points.Length, "torn touch snapshot");
        }
        Done(writer, "touch writer failed"); end(1);
        Check(driver.GetTouchPoints().Length == 0, "last contact lingered");
        begin(0,0,0); driver.Dispose();
        Check(driver.GetTouchPoints().Length == 0, "disposed touch driver retained contacts");
        Console.WriteLine("PASS: native touch IDs, concurrent mutation/snapshots and cleanup");
    }

    static void ProgressChecks()
    {
        for(int i=0;i<100;i++) ProgressHandler(ShaderCacheState.Loading,i,100);
        long before = GC.GetAllocatedBytesForCurrentThread();
        for(int i=0;i<10000;i++) ProgressHandler(ShaderCacheState.Loading,i,10000);
        Check(GC.GetAllocatedBytesForCurrentThread() == before, "unobserved progress allocated memory");
        string received = null;
        CallbackRegistry.RegisterManagedCallback("ProgressWithPTCorShaderCache", data => received = Encoding.UTF8.GetString(data));
        ProgressHandler(ShaderCacheState.Loaded,4,4);
        Check(received == "[\"Shaders\",4,4]", "observed completion progress lost");
        CallbackRegistry.UnregisterManagedCallback("ProgressWithPTCorShaderCache");
        Console.WriteLine("PASS: no-subscriber progress allocates zero bytes; subscribed completion delivered");
    }

    static byte[] Pfs(params (string Name, byte[] Data)[] entries)
    {
        byte[] names = Encoding.UTF8.GetBytes(string.Join('\0', entries.Select(e=>e.Name))+"\0");
        using var output = new MemoryStream(); using var writer = new BinaryWriter(output);
        writer.Write("PFS0"u8); writer.Write(entries.Length); writer.Write(names.Length); writer.Write(0);
        long offset=0; int nameOffset=0;
        foreach (var entry in entries) {
            writer.Write(offset); writer.Write((long)entry.Data.Length); writer.Write(nameOffset); writer.Write(0);
            offset+=entry.Data.Length; nameOffset+=Encoding.UTF8.GetByteCount(entry.Name)+1;
        }
        writer.Write(names); foreach(var entry in entries) writer.Write(entry.Data);
        return output.ToArray();
    }
    static (byte[] Ncz, byte[] Nca) Ncz(bool block)
    {
        byte[] header = new byte[0x4000], body = Enumerable.Repeat((byte)42,2*1024*1024+19).ToArray();
        using var output = new MemoryStream(); using var writer = new BinaryWriter(output);
        writer.Write(header); writer.Write("NCZSECTN"u8); writer.Write(1UL);
        writer.Write(0x4000UL); writer.Write((ulong)body.Length); writer.Write(1UL); writer.Write(0UL); writer.Write(new byte[32]);
        using var compressor = new ZstdSharp.Compressor();
        if(block) {
            int blockSize=1<<20, count=(body.Length+blockSize-1)/blockSize;
            var blocks=Enumerable.Range(0,count).Select(i=>compressor.Wrap(body.AsSpan(i*blockSize,Math.Min(blockSize,body.Length-i*blockSize))).ToArray()).ToArray();
            writer.Write("NCZBLOCK"u8); writer.Write((byte)2);writer.Write((byte)1);writer.Write((byte)0);writer.Write((byte)20);
            writer.Write(count);writer.Write((long)body.Length);
            foreach(var bytes in blocks) writer.Write(bytes.Length);
            foreach(var bytes in blocks) writer.Write(bytes);
        } else writer.Write(compressor.Wrap(body).ToArray());
        return (output.ToArray(),header.Concat(body).ToArray());
    }
    static unsafe void NszChecks(string root)
    {
        string temp = Path.Combine(root,"nsz-fixtures-"+Guid.NewGuid()); Directory.CreateDirectory(temp);
        try {
            foreach(bool block in new[]{false,true}) {
                var fixture=Ncz(block); string id=Convert.ToHexStringLower(SHA256.HashData(fixture.Nca))[..32];
                string source=Path.Combine(temp,$"source-{block}.nsz"), output=Path.Combine(temp,$"output-{block}.nsp");
                File.WriteAllBytes(source,Pfs((id+".ncz",fixture.Ncz),("rights.tik",new byte[16]),("extra.bin",new byte[37])));
                string digest=NszDecompressor.Decompress(source,output,100_000_000,(_,_)=>{});
                byte[] data=File.ReadAllBytes(output);
                Check(digest == Convert.ToHexStringLower(SHA256.HashData(data)), "NSZ whole-output streaming hash differs");
                Check(data.AsSpan(data.Length-37-16-fixture.Nca.Length,fixture.Nca.Length).SequenceEqual(fixture.Nca), "NCZ bytes changed");
                MustFail(()=>NszDecompressor.Decompress(source,output,100_000_000,(_,_)=>{}), "existing destination overwritten");
                File.Delete(output);
                MustFail(()=>NszDecompressor.Decompress(source,output,100_000_000,(written,_)=>{if(written>20000)throw new OperationCanceledException();}),"cancelled decode continued");
                Check(!File.Exists(output), "cancelled decode left output");
                // Keep the existing strict per-NCA validation when a ticket is present.
                File.WriteAllBytes(source,Pfs((new string('0',32)+".ncz",fixture.Ncz),("rights.tik",new byte[16])));
                MustFail(()=>NszDecompressor.Decompress(source,output,100_000_000,(_,_)=>{}), "bad NCA content ID accepted");
                Check(!File.Exists(output), "failed integrity check left output");
                // Ticketless repacks still use full-output hash, but keep upstream ID rules.
                File.WriteAllBytes(source,Pfs((new string('0',32)+".ncz",fixture.Ncz)));
                digest=NszDecompressor.Decompress(source,output,100_000_000,(_,_)=>{});
                Check(digest == Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(output))),"ticketless output hash differs");
            }
            string abiSource=Path.Combine(temp,"source-True.nsz"), abiOutput=Path.Combine(temp,"abi.nsp");
            var sourceBytes=Encoding.UTF8.GetBytes(abiSource+"\0"); var outputBytes=Encoding.UTF8.GetBytes(abiOutput+"\0");
            delegate* unmanaged[Cdecl]<byte*,byte*,long,delegate* unmanaged[Cdecl]<void*,long,long,int>,void*,int> decompress=&NszNative.Decompress;
            delegate* unmanaged[Cdecl]<IntPtr> getHash=&NszNative.GetLastSha256;
            delegate* unmanaged[Cdecl]<IntPtr,void> free=&NszNative.FreeString;
            fixed(byte* source=sourceBytes, output=outputBytes) {
                Check(decompress(source,output,100_000_000,null,null)==0,"NSZ native ABI failed");
                IntPtr hashPointer=getHash();
                try { Check(Marshal.PtrToStringUTF8(hashPointer)==Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(abiOutput))),"native ABI digest differs"); }
                finally { free(hashPointer); }
                Check(decompress(source,output,100_000_000,null,null)!=0 && getHash()==IntPtr.Zero,"failed import returned previous digest");
            }
        } finally { Directory.Delete(temp,true); }
        Console.WriteLine("PASS: NSZ solid/block streaming digests, NCA integrity, ticketless rules, cancellation and destination protection");
    }
    static void Main() { RendererChecks(); WindowAndMotionChecks(); TouchChecks(); ProgressChecks(); NszChecks(Directory.GetCurrentDirectory()); }
}
