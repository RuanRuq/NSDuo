using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace Ryujinx.Library
{
    partial class Library
    {
        // Protected by inputConfigurationLock, together with _window/_emulationContext.
        // This is false while loading and before either owner can begin disposal.
        private static bool _cheatContextReady;

        [UnmanagedCallersOnly(EntryPoint = "nsduo_cheat_request", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static nint CheatRequest(nint jsonPtr)
        {
            string titleId = "";
            string[] buildIds = Array.Empty<string>();
            try
            {
                string json = Marshal.PtrToStringUTF8(jsonPtr);
                if (string.IsNullOrEmpty(json) || json.Length > 4 * 1024 * 1024)
                    throw new ArgumentException("金手指请求为空或内容过大。");
                using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 16 });
                JsonElement request = document.RootElement;
                string action = RequiredCheatString(request, "action");
                if (action is not ("info" or "apply"))
                    throw new ArgumentException("无法识别金手指操作。");

                lock (inputConfigurationLock)
                {
                    if (!_cheatContextReady || _emulationContext == null || _window == null ||
                        _window.ExitRequested || Volatile.Read(ref _stopRequested) != 0)
                        throw new InvalidOperationException("当前游戏尚未准备好，或已经停止。");

                    // ActiveApplication throws while no program has been registered. Never
                    // infer identity from the library, filenames, or a previous session.
                    var application = _emulationContext.Processes.ActiveApplication;
                    if (application.ProgramId == 0 ||
                        !_emulationContext.TamperMachine.TryGetProcessInfo(application.ProgramId, application.ProcessId, out buildIds))
                        throw new InvalidOperationException("当前游戏的 Build ID 尚未准备好，或进程已经停止。");
                    titleId = application.ProgramId.ToString("X16", CultureInfo.InvariantCulture);

                    if (action == "apply")
                    {
                        string requestedTitle = RequiredCheatString(request, "titleID");
                        if (requestedTitle.Length != 16 ||
                            !ulong.TryParse(requestedTitle, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out ulong id) ||
                            id != application.ProgramId)
                            throw new ArgumentException("金手指所属游戏与当前运行游戏不一致。");

                        List<TamperMachine.ManagedCheat> cheats = ReadManagedCheats(request);
                        _emulationContext.TamperMachine.ReplaceManagedCheats(application.ProgramId, application.ProcessId, cheats);
                    }
                    return CheatResponse(true, action == "info" ? "" : "金手指开关已更新。", titleId, buildIds);
                }
            }
            catch (Exception error)
            {
                string message;
                if (error is JsonException)
                {
                    message = "金手指请求格式无效。";
                }
                else if (error is ArgumentException or InvalidOperationException)
                {
                    message = error.Message;
                }
                else
                {
                    Logger.Warning?.Print(LogClass.TamperMachine, $"Runtime cheat request failed: {error}");
                    message = "当前游戏的金手指运行状态暂不可用。";
                }
                if (string.IsNullOrWhiteSpace(message)) message = "金手指设置失败。";
                return CheatResponse(false, message, titleId, buildIds);
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "nsduo_free_cheat_response", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static void FreeCheatResponse(nint response)
        {
            if (response != nint.Zero) Marshal.FreeCoTaskMem(response);
        }

        private static List<TamperMachine.ManagedCheat> ReadManagedCheats(JsonElement request)
        {
            if (!request.TryGetProperty("groups", out JsonElement groups) || groups.ValueKind != JsonValueKind.Array || groups.GetArrayLength() > 1024)
                throw new ArgumentException("金手指分组无效。");
            List<TamperMachine.ManagedCheat> result = new();
            foreach (JsonElement group in groups.EnumerateArray())
            {
                if (group.ValueKind != JsonValueKind.Object || !group.TryGetProperty("entries", out JsonElement entries) ||
                    entries.ValueKind != JsonValueKind.Array || entries.GetArrayLength() > 1024)
                    throw new ArgumentException("金手指项目无效。");
                foreach (JsonElement entry in entries.EnumerateArray())
                {
                    if (entry.ValueKind != JsonValueKind.Object || !entry.TryGetProperty("enabled", out JsonElement enabled) ||
                        enabled.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                        throw new ArgumentException("金手指开关无效。");
                    // Disabled groups from another installed game version are harmless.
                    if (!enabled.GetBoolean()) continue;
                    if (result.Count >= 1024) throw new ArgumentException("启用的金手指项目过多。");
                    string buildId = RequiredCheatString(group, "buildID");
                    string id = RequiredCheatString(entry, "id");
                    string name = RequiredCheatString(entry, "name");
                    if (!entry.TryGetProperty("instructions", out JsonElement instructions) ||
                        instructions.ValueKind != JsonValueKind.Array || instructions.GetArrayLength() is 0 or > 16384)
                        throw new ArgumentException($"金手指“{name}”缺少有效指令。");
                    List<string> lines = new();
                    foreach (JsonElement line in instructions.EnumerateArray())
                    {
                        if (line.ValueKind != JsonValueKind.String) throw new ArgumentException("金手指指令格式无效。");
                        lines.Add(line.GetString());
                    }
                    result.Add(new(buildId, id, name, lines.ToArray()));
                }
            }
            return result;
        }

        private static string RequiredCheatString(JsonElement element, string property)
        {
            if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(property, out JsonElement value) ||
                value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString()))
                throw new ArgumentException($"金手指请求缺少 {property}。");
            return value.GetString();
        }

        private static nint CheatResponse(bool success, string message, string titleId, string[] buildIds)
        {
            // Explicit JSON writing stays compatible with NativeAOT without reflection.
            using MemoryStream stream = new();
            using (Utf8JsonWriter writer = new(stream))
            {
                writer.WriteStartObject();
                writer.WriteBoolean("success", success);
                writer.WriteString("message", message);
                writer.WriteString("titleID", titleId);
                writer.WriteStartArray("buildIDs");
                foreach (string buildId in buildIds) writer.WriteStringValue(buildId);
                writer.WriteEndArray();
                writer.WriteEndObject();
            }
            return Marshal.StringToCoTaskMemUTF8(Encoding.UTF8.GetString(stream.ToArray()));
        }
    }
}
