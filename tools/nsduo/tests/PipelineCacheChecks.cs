using System;
using System.Buffers.Binary;
using System.IO;
using Ryujinx.Graphics.Vulkan;

static class PipelineCacheChecks
{
    static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
    }

    static void Main()
    {
        PipelineConcurrencyChecks.Run();
        string root = Path.Combine(Path.GetTempPath(), "nsduo-pipeline-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            string path = Path.Combine(root, "game", "pipeline.cache");
            byte[] uuid = Guid.NewGuid().ToByteArray();
            byte[] data = new byte[4096];
            new Random(17).NextBytes(data);
            BinaryPrimitives.WriteUInt32LittleEndian(data, 32);
            BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(4), 1);
            BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(8), 0x106b);
            BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(12), 9);
            uuid.CopyTo(data, 16);
            PipelineCacheStorage storage = new(path, 0x106b, 9, 100, uuid);
            Check(storage.Load().Length == 0, "absent cache must be a miss");
            Check(storage.Save(data), "driver cache must survive application exit");
            Check(new PipelineCacheStorage(path, 0x106b, 9, 100, uuid).Load().AsSpan().SequenceEqual(data), "new session must reuse complete data");
            PipelineDriverChecks.Renderer.Run(path, data, uuid);
            Check(new PipelineCacheStorage(path, 0x106b, 9, 101, uuid).Load().Length == 0, "driver change must invalidate cache");
            Check(new PipelineCacheStorage(path, 0x106b, 10, 100, uuid).Load().Length == 0, "device change must invalidate cache");
            Check(new PipelineCacheStorage(path, 0x106b, 9, 100, Guid.NewGuid().ToByteArray()).Load().Length == 0, "UUID change must invalidate cache");
            byte[] original = File.ReadAllBytes(path);
            foreach (int offset in new[] { 0, 8, 40, original.Length - 1 })
            {
                byte[] corrupt = (byte[])original.Clone();
                corrupt[offset] ^= 0xff;
                File.WriteAllBytes(path, corrupt);
                Check(storage.Load().Length == 0, "corrupt header or payload must never reach driver");
            }
            File.WriteAllBytes(path, original.AsSpan(0, original.Length - 1).ToArray());
            Check(storage.Load().Length == 0, "truncated cache must be a miss");
            using (var file = File.Create(path)) file.SetLength(PipelineCacheStorage.MaxDataSize + 4096L);
            Check(storage.Load().Length == 0, "oversized file must be rejected before allocation");
            Check(storage.Save(data), "replace invalid cache atomically");
            byte[] invalid = (byte[])data.Clone();
            invalid[16] ^= 1;
            Check(!storage.Save(invalid), "foreign native header must be rejected");
            Check(!storage.Save(new byte[31]), "short native header must be rejected");
            Check(storage.Load().AsSpan().SequenceEqual(data), "failed save must preserve valid cache");
            Check(Directory.GetFiles(Path.GetDirectoryName(path)!, "*.tmp").Length == 0, "no temporary cache leaks");
            PipelineCacheStorage disabled = new(null, 0x106b, 9, 100, uuid);
            Check(!disabled.Save(data) && disabled.Load().Length == 0, "disabled cache does no IO");
            // A path blocked by a regular file must not turn optional caching into a game failure.
            PipelineCacheStorage denied = new(Path.Combine(path, "blocked"), 0x106b, 9, 100, uuid);
            Check(!denied.Save(data) && denied.Load().Length == 0, "IO failure must be harmless");
            Console.WriteLine("PASS pipeline cache persistence, identity, corruption, bounds, atomic replacement, disabled and IO failure");
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
