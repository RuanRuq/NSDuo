using System;
using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Ryujinx.Graphics.Vulkan
{
    internal sealed class PipelineCacheStorage
    {
        public const int MaxDataSize = 64 * 1024 * 1024;
        private const int EnvelopeSize = 72;
        private readonly string _path;
        private readonly uint _vendorId;
        private readonly uint _deviceId;
        private readonly byte[] _uuid;
        private readonly byte[] _identity;

        public PipelineCacheStorage(string path, uint vendorId, uint deviceId, uint driverVersion, ReadOnlySpan<byte> uuid)
        {
            _path = path;
            _vendorId = vendorId;
            _deviceId = deviceId;
            _uuid = uuid.ToArray();
            // Metal's compiler can change with the OS even when the Vulkan driver version does not.
            _identity = SHA256.HashData(Encoding.UTF8.GetBytes(
                $"{vendorId:X8}/{deviceId:X8}/{driverVersion:X8}/{Convert.ToHexString(uuid)}/{Environment.OSVersion.VersionString}"));
        }

        private bool ValidHeader(ReadOnlySpan<byte> data)
        {
            return data.Length >= 32 && data.Length <= MaxDataSize && _uuid.Length == 16 &&
                BinaryPrimitives.ReadUInt32LittleEndian(data) == 32 &&
                BinaryPrimitives.ReadUInt32LittleEndian(data[4..]) == 1 &&
                BinaryPrimitives.ReadUInt32LittleEndian(data[8..]) == _vendorId &&
                BinaryPrimitives.ReadUInt32LittleEndian(data[12..]) == _deviceId &&
                data.Slice(16, 16).SequenceEqual(_uuid);
        }

        public byte[] Load()
        {
            if (string.IsNullOrEmpty(_path)) return [];

            try
            {
                using FileStream file = new(_path, FileMode.Open, FileAccess.Read, FileShare.Read);
                long size = file.Length;
                if (size < EnvelopeSize + 32 || size > EnvelopeSize + MaxDataSize) return [];

                Span<byte> header = stackalloc byte[EnvelopeSize];
                file.ReadExactly(header);
                if (!header[..8].SequenceEqual("NSDVK001"u8) || !header.Slice(8, 32).SequenceEqual(_identity)) return [];

                byte[] data = new byte[(int)size - EnvelopeSize];
                file.ReadExactly(data);
                if (!ValidHeader(data) || !SHA256.HashData(data).AsSpan().SequenceEqual(header[40..])) return [];

                return data;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return [];
            }
        }

        public bool Save(ReadOnlySpan<byte> data)
        {
            if (string.IsNullOrEmpty(_path) || !ValidHeader(data)) return false;

            string temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path)));
                Span<byte> header = stackalloc byte[EnvelopeSize];
                "NSDVK001"u8.CopyTo(header);
                _identity.CopyTo(header[8..]);
                SHA256.HashData(data, header[40..]);
                using (FileStream file = new(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    file.Write(header);
                    file.Write(data);
                    file.Flush(flushToDisk: true);
                }

                // Keep the last good snapshot if writing or renaming fails.
                File.Move(temporary, _path, overwrite: true);
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return false;
            }
            finally
            {
                try { File.Delete(temporary); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
    }
}
