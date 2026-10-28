#nullable enable
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Ns;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.Ncm;
using Ryujinx.HLE.FileSystem;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using ContentType = LibHac.Ncm.ContentType;
using Path = System.IO.Path;
using SpanHelpers = LibHac.Common.SpanHelpers;

namespace Ryujinx.Library
{
    /// <summary>
    /// Reads package-owned CNMT/NACP metadata without starting emulation or consulting
    /// another installed update. The caller serializes inspection with key reloads and
    /// only invokes it while emulation is stopped.
    /// </summary>
    internal static class PackageInspector
    {
        private sealed record PackageContent(string Kind, ulong TitleId, ulong ApplicationId,
            uint Version, string? DisplayVersion, string? NcaPath);

        public static nint Inspect(VirtualFileSystem fileSystem, string? path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("游戏包路径为空。");
            }

            string extension = Path.GetExtension(path);
            if (!extension.Equals(".xci", StringComparison.OrdinalIgnoreCase) &&
                !extension.Equals(".nsp", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("请选择 XCI 或 NSP 游戏包。");
            }

            // Own the stream explicitly, including when opening a malformed container
            // fails. Do not retain NCA-backed objects after their files have closed.
            using FileStream stream = File.OpenRead(path);
            using IStorage storage = stream.AsStorage();
            using IFileSystem partition = OpenPartition(fileSystem.KeySet, storage, extension);
            fileSystem.ImportTickets(partition);

            Dictionary<string, string> ncaPaths = new(StringComparer.OrdinalIgnoreCase);
            List<Cnmt> metadata = new();

            foreach (DirectoryEntryEx entry in partition.EnumerateEntries("/", "*"))
            {
                if (!entry.FullPath.EndsWith(".nca", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (!ncaPaths.TryAdd(Path.GetFileName(entry.FullPath), entry.FullPath))
                {
                    throw new InvalidDataException("游戏包包含重复的 NCA 文件名。");
                }

                using UniqueRef<IFile> ncaFile = new();
                partition.OpenFile(ref ncaFile.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                Nca nca = new(fileSystem.KeySet, ncaFile.Get.AsStorage());

                // A filename is only a container lookup key. The decrypted NCA header
                // and CNMT determine the kind, IDs and version of every content item.
                if (nca.Header.ContentType == NcaContentType.Meta)
                {
                    ReadMetadata(nca, metadata);
                }
            }

            List<PackageContent> contents = new();
            HashSet<(ContentMetaType Type, ulong Id, uint Version)> seen = new();

            foreach (Cnmt cnmt in metadata)
            {
                string? kind = cnmt.Type switch
                {
                    ContentMetaType.Application => "application",
                    ContentMetaType.Patch => "patch",
                    ContentMetaType.AddOnContent => "dlc",
                    _ => null,
                };

                if (kind == null || !seen.Add((cnmt.Type, cnmt.TitleId, cnmt.TitleVersion.Version)))
                {
                    continue;
                }

                ulong applicationId = cnmt.Type == ContentMetaType.Application
                    ? cnmt.TitleId : cnmt.ApplicationTitleId;

                if (cnmt.TitleId == 0 || applicationId == 0)
                {
                    throw new InvalidDataException("CNMT 缺少有效的内容 ID 或主应用 ID。");
                }

                if (cnmt.Type == ContentMetaType.AddOnContent)
                {
                    AddDownloadableContents(fileSystem.KeySet, partition, ncaPaths, cnmt, applicationId, contents);
                }
                else
                {
                    ValidateProgram(fileSystem.KeySet, partition, ncaPaths, cnmt, applicationId);
                    string? displayVersion = ReadDisplayVersion(fileSystem.KeySet, partition, ncaPaths, cnmt);
                    contents.Add(new PackageContent(kind, cnmt.TitleId, applicationId,
                        cnmt.TitleVersion.Version, displayVersion, null));
                }
            }

            if (contents.Count == 0)
            {
                throw new InvalidDataException("游戏包中未找到可识别的本体、更新或 DLC 内容元数据。");
            }

            return CreateResponse(contents, null);
        }

        private static IFileSystem OpenPartition(KeySet keySet, IStorage storage, string extension)
        {
            if (extension.Equals(".xci", StringComparison.OrdinalIgnoreCase))
            {
                return new Xci(keySet, storage).OpenPartition(XciPartitionType.Secure);
            }

            PartitionFileSystem partition = new();
            try
            {
                partition.Initialize(storage).ThrowIfFailure();
                return partition;
            }
            catch
            {
                partition.Dispose();
                throw;
            }
        }

        private static void ReadMetadata(Nca nca, List<Cnmt> metadata)
        {
            using IFileSystem metaFileSystem = nca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
            bool found = false;

            foreach (DirectoryEntryEx entry in metaFileSystem.EnumerateEntries("/", "*.cnmt"))
            {
                using UniqueRef<IFile> file = new();
                metaFileSystem.OpenFile(ref file.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                file.Get.GetSize(out long size).ThrowIfFailure();
                if (size < 0x20 || size > 16 * 1024 * 1024)
                {
                    throw new InvalidDataException("CNMT 元数据长度无效。");
                }

                using Stream cnmtStream = file.Release().AsStream();
                Cnmt cnmt = new(cnmtStream);
                if (cnmt.TitleId != nca.Header.TitleId)
                {
                    throw new InvalidDataException("CNMT 内容 ID 与所属 NCA 不一致。");
                }

                metadata.Add(cnmt);
                found = true;
            }

            if (!found)
            {
                throw new InvalidDataException("Meta NCA 中没有 CNMT 元数据。");
            }
        }

        private static string GetContentPath(Dictionary<string, string> paths, CnmtContentEntry entry)
        {
            string name = $"{Convert.ToHexStringLower(entry.NcaId)}.nca";
            if (!paths.TryGetValue(name, out string? path))
            {
                throw new InvalidDataException($"游戏包缺少 CNMT 引用的内容：{name}");
            }

            return path;
        }

        private static void ValidateProgram(KeySet keySet, IFileSystem partition,
            Dictionary<string, string> paths, Cnmt cnmt, ulong applicationId)
        {
            bool found = false;
            foreach (CnmtContentEntry entry in cnmt.ContentEntries)
            {
                if (entry.Type != ContentType.Program)
                {
                    continue;
                }

                using UniqueRef<IFile> file = new();
                partition.OpenFile(ref file.Ref, GetContentPath(paths, entry).ToU8Span(), OpenMode.Read).ThrowIfFailure();
                Nca nca = new(keySet, file.Get.AsStorage());
                if (nca.Header.ContentType != NcaContentType.Program ||
                    (nca.Header.TitleId & ~0x1FFFUL) != applicationId)
                {
                    throw new InvalidDataException("Program NCA 与 CNMT 主应用不匹配。");
                }

                found = true;
            }

            if (!found)
            {
                throw new InvalidDataException($"内容 {cnmt.TitleId:x16} 没有可加载的 Program NCA。");
            }
        }

        private static string? ReadDisplayVersion(KeySet keySet, IFileSystem partition,
            Dictionary<string, string> paths, Cnmt cnmt)
        {
            foreach (CnmtContentEntry entry in cnmt.ContentEntries)
            {
                if (entry.Type != ContentType.Control)
                {
                    continue;
                }

                using UniqueRef<IFile> file = new();
                partition.OpenFile(ref file.Ref, GetContentPath(paths, entry).ToU8Span(), OpenMode.Read).ThrowIfFailure();
                Nca nca = new(keySet, file.Get.AsStorage());
                if (nca.Header.ContentType != NcaContentType.Control)
                {
                    throw new InvalidDataException("CNMT 引用的 Control NCA 类型不正确。");
                }
                if (nca.ProgramIndex != 0)
                {
                    continue;
                }

                using IFileSystem controlFileSystem = nca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
                using UniqueRef<IFile> nacpFile = new();
                controlFileSystem.OpenFile(ref nacpFile.Ref, "/control.nacp".ToU8Span(), OpenMode.Read).ThrowIfFailure();
                ApplicationControlProperty control = new();
                Span<byte> controlBytes = SpanHelpers.AsByteSpan(ref control);
                nacpFile.Get.Read(out long bytesRead, 0, controlBytes, ReadOption.None).ThrowIfFailure();
                if (bytesRead != controlBytes.Length)
                {
                    throw new InvalidDataException("control.nacp 数据不完整。");
                }

                string version = control.DisplayVersionString.ToString();
                return string.IsNullOrWhiteSpace(version) ? null : version;
            }

            return null;
        }

        private static void AddDownloadableContents(KeySet keySet, IFileSystem partition,
            Dictionary<string, string> paths, Cnmt cnmt, ulong applicationId, List<PackageContent> contents)
        {
            int initialCount = contents.Count;
            foreach (CnmtContentEntry entry in cnmt.ContentEntries)
            {
                if (entry.Type != ContentType.Data)
                {
                    continue;
                }

                string path = GetContentPath(paths, entry);
                using UniqueRef<IFile> file = new();
                partition.OpenFile(ref file.Ref, path.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                Nca nca = new(keySet, file.Get.AsStorage());
                if (nca.Header.ContentType != NcaContentType.PublicData || nca.Header.TitleId != cnmt.TitleId)
                {
                    throw new InvalidDataException("DLC Data NCA 与 CNMT 内容 ID 或类型不匹配。");
                }

                contents.Add(new PackageContent("dlc", cnmt.TitleId, applicationId,
                    cnmt.TitleVersion.Version, null, path));
            }

            if (contents.Count == initialCount)
            {
                throw new InvalidDataException($"DLC {cnmt.TitleId:x16} 没有可加载的 Data NCA。");
            }
        }

        // Manual UTF-8 JSON writing is NativeAOT-safe and does not require reflection
        // or source-generated DTO roots. Swift releases this allocation in a defer.
        private static nint CreateResponse(List<PackageContent>? contents, string? error)
        {
            using MemoryStream buffer = new();
            using (Utf8JsonWriter writer = new(buffer))
            {
                writer.WriteStartObject();
                writer.WriteString("error", error);
                writer.WriteStartArray("contents");
                if (contents != null)
                {
                    foreach (PackageContent content in contents)
                    {
                        writer.WriteStartObject();
                        writer.WriteString("kind", content.Kind);
                        writer.WriteString("titleID", content.TitleId.ToString("x16"));
                        writer.WriteString("applicationID", content.ApplicationId.ToString("x16"));
                        writer.WriteNumber("version", content.Version);
                        writer.WriteString("displayVersion", content.DisplayVersion);
                        writer.WriteString("ncaPath", content.NcaPath);
                        writer.WriteEndObject();
                    }
                }
                writer.WriteEndArray();
                writer.WriteEndObject();
            }

            byte[] bytes = buffer.ToArray();
            nint pointer = Marshal.AllocHGlobal(checked(bytes.Length + 1));
            try
            {
                Marshal.Copy(bytes, 0, pointer, bytes.Length);
                Marshal.WriteByte(pointer, bytes.Length, 0);
                return pointer;
            }
            catch
            {
                Marshal.FreeHGlobal(pointer);
                throw;
            }
        }

        public static nint CreateError(Exception exception)
        {
            try
            {
                string message = exception switch
                {
                    MissingKeyException missing => $"缺少解密密钥 {missing.Name}，请导入与游戏版本匹配的 prod.keys。",
                    UnauthorizedAccessException => "无法访问游戏包，请重新选择文件或文件夹。",
                    FileNotFoundException => "找不到游戏包，请确认文件仍在原位置。",
                    InvalidDataException => $"游戏包数据无效、缺失或密钥不匹配：{exception.Message}",
                    _ => $"无法读取游戏包：{exception.Message}",
                };
                return CreateResponse(null, message);
            }
            catch
            {
                // Even an allocation failure must not unwind through the unmanaged ABI.
                return nint.Zero;
            }
        }
    }
}
