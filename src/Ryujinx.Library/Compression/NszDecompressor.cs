using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using ZstdSharp;
using ZstdSharp.Unsafe;

namespace Ryujinx.Library
{
    // Format reference: https://github.com/nicoboss/nsz/blob/master/docs/formats.md
    // Section/counter semantics: nsz/Decompressor.py and nsz/nut/aes128.py.
    // This produces a new PFS0/NSP, restoring encrypted NCA bytes, without keys
    // from the emulator. NCZ carries the per-section keys/counters itself.
    internal static class NszDecompressor
    {
        private const int NcaHeaderSize = 0x4000;
        private const int BufferSize = 1024 * 1024;
        private const int MaxTableBytes = 16 * 1024 * 1024;
        private const int MaxFiles = 65536;
        private const int MaxSections = 65536;
        private const long MaxOutputBytes = 1L << 40;
        private static readonly UTF8Encoding StrictUtf8 = new(false, true);

        private sealed record Entry(string Name, string OutputName, long Offset, long Size, long OutputSize);
        private sealed record Section(long Offset, long Size, ulong CryptoType, byte[] Key, byte[] Counter);
        private sealed record NczMetadata(List<Section> Sections, long OutputSize, long PayloadOffset,
            long PayloadSize, uint[] BlockSizes, long BlockSize);

        internal static string Decompress(string sourcePath, string destinationPath, long availableBytes,
            Action<long, long> progress)
        {
            if (Path.GetFullPath(sourcePath) == Path.GetFullPath(destinationPath))
            {
                throw new IOException("NSZ 源文件与目标文件不能相同。");
            }
            if (availableBytes <= 0)
            {
                throw new IOException("手机可用空间不足，无法解压 NSZ。");
            }

            bool ownsDestination = false;
            try
            {
                using FileStream source = new(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read,
                    BufferSize, FileOptions.SequentialScan);
                long sourceLength = source.Length;
                List<Entry> entries = ReadEntries(source, availableBytes, progress);
                // Upstream Nsp.ticket() marks the container ticketless when its
                // directory has no Ticket (.tik) entry. Such repacks can preserve
                // content IDs while changing NCA headers; see Fs/Nsp.py and
                // Decompressor.py in the official NSZ repository.
                bool ticketless = !entries.Any(entry => entry.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase));
                byte[] header = CreatePfsHeader(entries);
                long outputSize = header.Length;
                foreach (Entry entry in entries)
                {
                    outputSize = CheckedSize(outputSize, entry.OutputSize);
                }
                if (outputSize > availableBytes)
                {
                    throw new IOException($"解压后需要约 {Math.Ceiling(outputSize / 1048576d):0} MB，可用空间不足。");
                }
                progress(0, outputSize);

                // CreateNew is deliberate: even on failure, never overwrite/delete a
                // pre-existing game or a destination belonging to another import.
                using (FileStream file = new(destinationPath, FileMode.CreateNew, FileAccess.Write,
                    FileShare.None, BufferSize, FileOptions.SequentialScan))
                {
                    ownsDestination = true;
                    using HashingWriteStream destination = new(file);
                    destination.Write(header);
                    long written = header.Length;
                    byte[] buffer = new byte[BufferSize];
                    foreach (Entry entry in entries)
                    {
                        progress(written, outputSize);
                        long entryStart = destination.Position;
                        if (entry.Name.EndsWith(".ncz", StringComparison.OrdinalIgnoreCase))
                        {
                            RestoreNcz(source, destination, entry, buffer, ticketless, progress, written, outputSize);
                        }
                        else
                        {
                            source.Position = entry.Offset;
                            using LimitedReadStream input = new(source, entry.Size);
                            CopyExactly(input, destination, entry.Size, buffer, null, null,
                                progress, written, outputSize);
                        }
                        if (destination.Position - entryStart != entry.OutputSize)
                        {
                            throw new InvalidDataException("NSZ 解压条目长度不一致。");
                        }
                        written = CheckedSize(written, entry.OutputSize);
                    }
                    if (source.Length != sourceLength || destination.Position != outputSize)
                    {
                        throw new InvalidDataException("NSZ 文件在读取期间发生变化或解压长度不一致。");
                    }
                    progress(written, outputSize);
                    file.Flush(flushToDisk: true);
                    progress(written, outputSize);
                    return destination.FinishHash();
                }
            }
            catch
            {
                if (ownsDestination)
                {
                    try { File.Delete(destinationPath); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
                throw;
            }
        }

        // Hash the complete reconstructed NSP, including its PFS header. The
        // separate per-NCA integrity checks below remain unchanged.
        private sealed class HashingWriteStream(Stream output) : Stream
        {
            private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            public string FinishHash() => Convert.ToHexStringLower(_hash.GetHashAndReset());
            public override void Write(ReadOnlySpan<byte> bytes)
            {
                output.Write(bytes);
                _hash.AppendData(bytes);
            }
            public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));
            public override bool CanRead => false;
            public override bool CanSeek => false;
            public override bool CanWrite => true;
            public override long Length => output.Length;
            public override long Position { get => output.Position; set => throw new NotSupportedException(); }
            public override void Flush() => output.Flush();
            public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            protected override void Dispose(bool disposing)
            {
                if (disposing) _hash.Dispose();
                base.Dispose(disposing); // The enclosing scope owns the file.
            }
        }

        private static List<Entry> ReadEntries(FileStream source, long availableBytes, Action<long, long> progress)
        {
            using BinaryReader reader = new(source, StrictUtf8, leaveOpen: true);
            if (source.Length < 16 || !ReadBytes(reader, 4).AsSpan().SequenceEqual("PFS0"u8))
            {
                throw new InvalidDataException("NSZ 文件不是有效的 PFS0 容器。");
            }
            uint count = reader.ReadUInt32();
            uint stringsSize = reader.ReadUInt32();
            reader.ReadUInt32();
            if (count == 0 || count > MaxFiles || stringsSize == 0 || stringsSize > MaxTableBytes)
            {
                throw new InvalidDataException("NSZ 文件目录数量或字符串表大小无效。");
            }
            long dataOffset = 16 + count * 24L + stringsSize;
            if (dataOffset > source.Length)
            {
                throw new InvalidDataException("NSZ 文件目录被截断。");
            }
            byte[] table = ReadBytes(reader, checked((int)count * 24));
            byte[] strings = ReadBytes(reader, (int)stringsSize);
            List<Entry> entries = new((int)count);
            HashSet<string> names = new(StringComparer.OrdinalIgnoreCase);
            long totalOutputSize = 0;
            for (int index = 0; index < count; index++)
            {
                progress(0, 0);
                ReadOnlySpan<byte> row = table.AsSpan(index * 24, 24);
                long offset = ToSize(BinaryPrimitives.ReadUInt64LittleEndian(row));
                long size = ToSize(BinaryPrimitives.ReadUInt64LittleEndian(row[8..]));
                uint nameOffset = BinaryPrimitives.ReadUInt32LittleEndian(row[16..]);
                if (nameOffset >= stringsSize || offset > source.Length - dataOffset ||
                    size > source.Length - dataOffset - offset)
                {
                    throw new InvalidDataException("NSZ 文件条目超出了容器范围。");
                }
                int nameEnd = Array.IndexOf(strings, (byte)0, (int)nameOffset);
                if (nameEnd < 0 || nameEnd - nameOffset is < 1 or > 1024)
                {
                    throw new InvalidDataException("NSZ 文件条目名称无效。");
                }
                string name = StrictUtf8.GetString(strings, (int)nameOffset, nameEnd - (int)nameOffset);
                if (name.IndexOfAny(new[] { '/', '\\', ':' }) >= 0 || name is "." or "..")
                {
                    throw new InvalidDataException("NSZ 文件包含无效的条目路径。");
                }
                bool compressed = name.EndsWith(".ncz", StringComparison.OrdinalIgnoreCase);
                string outputName = compressed ? name[..^4] + ".nca" : name;
                if (!names.Add(outputName))
                {
                    throw new InvalidDataException("NSZ 文件包含重复的条目名称。");
                }
                long absoluteOffset = checked(dataOffset + offset);
                long outputSize = compressed ? ReadNczMetadata(source, absoluteOffset, size, progress).OutputSize : size;
                totalOutputSize = CheckedSize(totalOutputSize, outputSize);
                if (totalOutputSize > availableBytes)
                {
                    throw new IOException("手机可用空间不足以存放解压后的 NSP 文件。");
                }
                entries.Add(new Entry(name, outputName, absoluteOffset, size, outputSize));
            }

            long previousEnd = dataOffset;
            foreach (Entry entry in entries.OrderBy(entry => entry.Offset))
            {
                if (entry.Offset < previousEnd)
                {
                    throw new InvalidDataException("NSZ 文件的条目范围发生重叠。");
                }
                previousEnd = checked(entry.Offset + entry.Size);
            }
            return entries;
        }

        private static NczMetadata ReadNczMetadata(FileStream source, long offset, long size,
            Action<long, long> progress)
        {
            if (size < NcaHeaderSize + 16 + 64 + 4)
            {
                throw new InvalidDataException("NCZ 文件头被截断。");
            }
            source.Position = offset + NcaHeaderSize;
            using LimitedReadStream limited = new(source, size - NcaHeaderSize);
            using BinaryReader reader = new(limited, StrictUtf8, leaveOpen: true);
            if (!ReadBytes(reader, 8).AsSpan().SequenceEqual("NCZSECTN"u8))
            {
                throw new InvalidDataException("NCZ 缺少 NCZSECTN 文件头。");
            }
            ulong count = reader.ReadUInt64();
            if (count == 0 || count > MaxSections || count * 64 > (ulong)limited.Remaining)
            {
                throw new InvalidDataException("NCZ 加密区段目录无效。");
            }
            List<Section> sections = new((int)count + 1);
            long previousEnd = NcaHeaderSize;
            for (ulong index = 0; index < count; index++)
            {
                if (index % 256 == 0) { progress(0, 0); }
                long sectionOffset = ToSize(reader.ReadUInt64());
                long sectionSize = ToSize(reader.ReadUInt64());
                ulong cryptoType = reader.ReadUInt64();
                reader.ReadUInt64();
                byte[] key = ReadBytes(reader, 16);
                byte[] counter = ReadBytes(reader, 16);
                long end = CheckedSize(sectionOffset, sectionSize);
                if (sectionSize == 0 || (cryptoType != 1 && cryptoType != 3 && cryptoType != 4))
                {
                    throw new InvalidDataException("NCZ 区段为空，或使用了尚不支持的加密类型。");
                }
                if (index == 0)
                {
                    if (end <= NcaHeaderSize)
                    {
                        throw new InvalidDataException("NCZ 首个区段未包含有效数据。");
                    }
                    if (sectionOffset > NcaHeaderSize)
                    {
                        sections.Add(new Section(NcaHeaderSize, sectionOffset - NcaHeaderSize, 1, null, null));
                    }
                    // The first 0x4000 bytes were stored verbatim even if a section
                    // starts before them. They must not be decoded a second time.
                    sectionOffset = Math.Max(sectionOffset, NcaHeaderSize);
                }
                else if (sectionOffset != previousEnd)
                {
                    throw new InvalidDataException("NCZ 区段不连续或相互重叠。");
                }
                sections.Add(new Section(sectionOffset, end - sectionOffset, cryptoType, key, counter));
                previousEnd = end;
            }
            long payloadOffset = source.Position;
            long decodedSize = previousEnd - NcaHeaderSize;
            uint[] blocks = null;
            long blockSize = 0;
            if (limited.Remaining >= 8)
            {
                byte[] magic = ReadBytes(reader, 8);
                if (magic.AsSpan().SequenceEqual("NCZBLOCK"u8))
                {
                    int version = reader.ReadByte();
                    int type = reader.ReadByte();
                    int reserved = reader.ReadByte();
                    int exponent = reader.ReadByte();
                    uint blockCount = reader.ReadUInt32();
                    long declaredDecodedSize = ToSize(reader.ReadUInt64());
                    if (version != 2 || type != 1 || reserved != 0 || exponent is < 14 or > 32)
                    {
                        throw new InvalidDataException("不支持此 NCZBLOCK 版本或分块参数。");
                    }
                    blockSize = 1L << exponent;
                    long expectedCount = (decodedSize + blockSize - 1) / blockSize;
                    if (declaredDecodedSize != decodedSize || blockCount != expectedCount ||
                        blockCount == 0 || blockCount > MaxTableBytes / 4 || blockCount * 4L > limited.Remaining)
                    {
                        throw new InvalidDataException("NCZ 分块数量或解压长度无效。");
                    }
                    blocks = new uint[blockCount];
                    long compressedSize = 0;
                    for (int index = 0; index < blocks.Length; index++)
                    {
                        if (index % 4096 == 0) { progress(0, 0); }
                        blocks[index] = reader.ReadUInt32();
                        long expected = Math.Min(blockSize, decodedSize - index * blockSize);
                        if (blocks[index] == 0 || blocks[index] > expected)
                        {
                            throw new InvalidDataException("NCZ 分块长度无效。");
                        }
                        compressedSize = checked(compressedSize + blocks[index]);
                    }
                    if (compressedSize != limited.Remaining)
                    {
                        throw new InvalidDataException("NCZ 分块数据被截断或包含多余数据。");
                    }
                    payloadOffset = source.Position;
                }
            }
            long payloadSize = checked(offset + size - payloadOffset);
            if (payloadSize <= 0)
            {
                throw new InvalidDataException("NCZ 缺少压缩数据。");
            }
            return new NczMetadata(sections, previousEnd, payloadOffset, payloadSize, blocks, blockSize);
        }

        private static byte[] CreatePfsHeader(List<Entry> entries)
        {
            int stringsSize = entries.Sum(entry => StrictUtf8.GetByteCount(entry.OutputName) + 1);
            if (stringsSize > MaxTableBytes)
            {
                throw new InvalidDataException("NSZ 的输出文件目录超过安全大小上限。");
            }
            int unpaddedSize = checked(16 + entries.Count * 24 + stringsSize);
            int padding = (16 - unpaddedSize % 16) % 16;
            byte[] header = new byte[checked(unpaddedSize + padding)];
            using MemoryStream stream = new(header, writable: true);
            using BinaryWriter writer = new(stream, StrictUtf8);
            writer.Write("PFS0"u8);
            writer.Write(entries.Count);
            writer.Write(stringsSize + padding);
            writer.Write(0);
            long dataOffset = 0;
            int stringOffset = 0;
            foreach (Entry entry in entries)
            {
                writer.Write(dataOffset);
                writer.Write(entry.OutputSize);
                writer.Write(stringOffset);
                writer.Write(0);
                dataOffset = CheckedSize(dataOffset, entry.OutputSize);
                stringOffset += StrictUtf8.GetByteCount(entry.OutputName) + 1;
            }
            foreach (Entry entry in entries)
            {
                writer.Write(StrictUtf8.GetBytes(entry.OutputName));
                writer.Write((byte)0);
            }
            return header;
        }

        private static void RestoreNcz(FileStream source, Stream destination, Entry entry, byte[] buffer,
            bool ticketless, Action<long, long> progress, long writtenBeforeEntry, long total)
        {
            NczMetadata metadata = ReadNczMetadata(source, entry.Offset, entry.Size,
                (_, _) => progress(writtenBeforeEntry, total));
            if (metadata.OutputSize != entry.OutputSize)
            {
                throw new InvalidDataException("NCZ 区段目录在读取期间发生变化。");
            }
            using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            source.Position = entry.Offset;
            source.ReadExactly(buffer.AsSpan(0, NcaHeaderSize));
            destination.Write(buffer.AsSpan(0, NcaHeaderSize));
            hash.AppendData(buffer, 0, NcaHeaderSize);
            source.Position = metadata.PayloadOffset;
            using LimitedReadStream compressed = new(source, metadata.PayloadSize);
            using Stream payload = metadata.BlockSizes == null
                ? CreateZstdStream(compressed)
                : new BlockPayloadStream(compressed, metadata);
            long written = writtenBeforeEntry + NcaHeaderSize;
            foreach (Section section in metadata.Sections)
            {
                using CtrTransform crypto = section.CryptoType is 3 or 4
                    ? new CtrTransform(section.Key, section.Counter) : null;
                CopyExactly(payload, destination, section.Size, buffer, hash,
                    crypto == null ? null : (data, count, relative) => crypto.Transform(data, count, section.Offset + relative),
                    progress, written, total);
                written += section.Size;
            }
            if (payload.ReadByte() != -1 || compressed.Remaining != 0)
            {
                throw new InvalidDataException("NCZ 解压数据长度超过区段声明，文件可能已损坏。");
            }

            // Standard content IDs are the first 16 bytes of the encrypted NCA
            // SHA-256. Upstream skips this comparison for ticketless containers
            // because repacked NCA headers may differ while retaining the content
            // ID. The container/section/block lengths and zstd stream are still
            // validated above in both modes.
            string contentId = entry.OutputName.Split('.')[0];
            byte[] digest = hash.GetHashAndReset();
            if (!ticketless && contentId.Length == 32 && contentId.All(Uri.IsHexDigit) &&
                !Convert.ToHexString(digest.AsSpan(0, 16)).Equals(contentId, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException($"NCZ 条目 {entry.Name} 的内容校验失败，无法导入。");
            }
        }

        private static void CopyExactly(Stream input, Stream output, long size, byte[] buffer,
            IncrementalHash hash, Action<byte[], int, long> transform, Action<long, long> progress,
            long writtenBefore, long total)
        {
            long copied = 0;
            while (copied < size)
            {
                progress(writtenBefore + copied, total);
                int count = input.Read(buffer, 0, (int)Math.Min(buffer.Length, size - copied));
                if (count == 0)
                {
                    throw new EndOfStreamException("NSZ 压缩数据被截断，无法完整解压。");
                }
                transform?.Invoke(buffer, count, copied);
                output.Write(buffer, 0, count);
                hash?.AppendData(buffer, 0, count);
                copied += count;
            }
        }

        private static DecompressionStream CreateZstdStream(Stream source)
        {
            DecompressionStream stream = new(source, bufferSize: 128 * 1024, checkEndOfStream: true, leaveOpen: true);
            try
            {
                // Bound memory even for a malicious frame. The regular/long-distance
                // NSZ defaults fit this 128 MiB window; larger custom windows fail.
                stream.SetParameter(ZSTD_dParameter.ZSTD_d_windowLogMax, 27);
                return stream;
            }
            catch
            {
                stream.Dispose();
                throw;
            }
        }

        private static long ToSize(ulong value)
        {
            if (value > MaxOutputBytes) { throw new InvalidDataException("NSZ 声明的长度超过安全上限。"); }
            return (long)value;
        }

        private static long CheckedSize(long first, long second)
        {
            long result = checked(first + second);
            if (result > MaxOutputBytes) { throw new InvalidDataException("NSZ 解压大小超过安全上限。"); }
            return result;
        }

        private static byte[] ReadBytes(BinaryReader reader, int count)
        {
            byte[] bytes = reader.ReadBytes(count);
            if (bytes.Length != count) { throw new EndOfStreamException("NSZ 文件头被截断。"); }
            return bytes;
        }

        // Reads only one PFS0 entry/block, so decoder lookahead cannot consume a
        // following entry. Ownership stays with the outer synchronous operation.
        private sealed class LimitedReadStream : Stream
        {
            private readonly Stream _source;
            public long Remaining { get; private set; }
            public LimitedReadStream(Stream source, long size) { _source = source; Remaining = size; }
            public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
            public override int Read(Span<byte> buffer)
            {
                int count = _source.Read(buffer[..(int)Math.Min(buffer.Length, Remaining)]);
                Remaining -= count;
                return count;
            }
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override void Flush() => throw new NotSupportedException();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        }

        // Even a 4 GiB NCZ block is streamed. No compressed/uncompressed whole-block
        // allocation is made, and raw blocks (stored size == decoded size) bypass zstd.
        private sealed class BlockPayloadStream : Stream
        {
            private readonly Stream _source;
            private readonly NczMetadata _metadata;
            private int _index;
            private long _remaining;
            private Stream _block;
            private LimitedReadStream _compressedBlock;

            public BlockPayloadStream(Stream source, NczMetadata metadata) { _source = source; _metadata = metadata; }
            public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
            public override int Read(Span<byte> buffer)
            {
                if (buffer.Length == 0) { return 0; }
                if (_block != null && _remaining == 0) { FinishBlock(); }
                if (_block == null)
                {
                    if (_index == _metadata.BlockSizes.Length) { return 0; }
                    long decodedSize = Math.Min(_metadata.BlockSize,
                        _metadata.OutputSize - NcaHeaderSize - _index * _metadata.BlockSize);
                    uint compressedSize = _metadata.BlockSizes[_index++];
                    _compressedBlock = new LimitedReadStream(_source, compressedSize);
                    _block = compressedSize == decodedSize ? _compressedBlock : CreateZstdStream(_compressedBlock);
                    _remaining = decodedSize;
                }
                int count = _block.Read(buffer[..(int)Math.Min(buffer.Length, _remaining)]);
                if (count == 0) { throw new EndOfStreamException("NCZ 分块数据被截断。"); }
                _remaining -= count;
                return count;
            }
            private void FinishBlock()
            {
                if (_block.ReadByte() != -1 || _compressedBlock.Remaining != 0)
                {
                    throw new InvalidDataException("NCZ 分块解压长度不一致。");
                }
                _block.Dispose();
                _block = null;
                _compressedBlock.Dispose();
                _compressedBlock = null;
            }
            protected override void Dispose(bool disposing)
            {
                if (disposing) { _block?.Dispose(); _compressedBlock?.Dispose(); }
                base.Dispose(disposing);
            }
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override void Flush() => throw new NotSupportedException();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        }

        // NCZ CTR = first 8 counter bytes || big-endian absolute NCA offset / 16.
        // AES-ECB batches counters, then XORs the resulting keystream, including
        // unaligned boundaries. Apple's AES implementation is available to NativeAOT.
        private sealed class CtrTransform : IDisposable
        {
            private readonly Aes _aes;
            private readonly byte[] _nonce;
            private readonly byte[] _counters = new byte[BufferSize + 16];
            private readonly byte[] _keyStream = new byte[BufferSize + 16];
            public CtrTransform(byte[] key, byte[] counter)
            {
                _aes = Aes.Create();
                _aes.Key = key;
                _nonce = counter.AsSpan(0, 8).ToArray();
            }
            public void Transform(byte[] bytes, int count, long offset)
            {
                int skip = (int)(offset & 15);
                int padded = (skip + count + 15) & ~15;
                ulong block = (ulong)(offset >> 4);
                for (int index = 0; index < padded; index += 16)
                {
                    _nonce.CopyTo(_counters, index);
                    BinaryPrimitives.WriteUInt64BigEndian(_counters.AsSpan(index + 8, 8), block++);
                }
                _aes.EncryptEcb(_counters.AsSpan(0, padded), _keyStream, PaddingMode.None);
                for (int index = 0; index < count; index++) { bytes[index] ^= _keyStream[skip + index]; }
            }
            public void Dispose()
            {
                _aes.Dispose();
                CryptographicOperations.ZeroMemory(_keyStream);
            }
        }
    }
}
