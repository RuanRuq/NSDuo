using Ryujinx.Common.Logging;
using Silk.NET.Core.Loader;
using Silk.NET.Vulkan;
using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Ryujinx.Graphics.Vulkan.MoltenVK
{
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    public static partial class MVKInitialization
    {
        private const string VulkanLib = "libvulkan.dylib";

        [LibraryImport("libMoltenVK.dylib")]
        private static partial Result vkGetMoltenVKConfigurationMVK(nint unusedInstance, out MVKConfiguration config, ref nint configSize);

        [LibraryImport("libMoltenVK.dylib")]
        private static partial Result vkSetMoltenVKConfigurationMVK(nint unusedInstance, in MVKConfiguration config, ref nint configSize);

        private static MVKConfiguration ReadConfiguration()
        {
            nint configSize = Marshal.SizeOf<MVKConfiguration>();
            Result result = vkGetMoltenVKConfigurationMVK(nint.Zero, out MVKConfiguration config, ref configSize);

            // A newer MoltenVK may append fields. VK_INCOMPLETE is expected when
            // reading our older prefix, provided every field we use was copied.
            if (result != Result.Success && result != Result.Incomplete) throw new VulkanException(result);
            nint requiredSize = Marshal.OffsetOf<MVKConfiguration>(nameof(MVKConfiguration.UseMetalArgumentBuffers)) + sizeof(uint);
            if (configSize < requiredSize)
            {
                throw new InvalidOperationException($"MoltenVK configuration prefix is too short: {configSize} bytes, need {requiredSize}.");
            }

            return config;
        }

        public static void Initialize()
        {
            nint configSize = (nint)Marshal.SizeOf<MVKConfiguration>();

            MVKConfiguration config = ReadConfiguration();
            bool previouslySynchronous = config.SynchronousQueueSubmits;

            config.UseMetalArgumentBuffers = true;
            config.FastMathEnabled = true;

            config.SemaphoreSupportStyle = MVKVkSemaphoreSupportStyle.MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE_SINGLE_QUEUE;
            // Keep command order and all fences, while MoltenVK processes queue
            // submissions on its own serial worker instead of the backend thread.
            config.SynchronousQueueSubmits = false;

            config.ResumeLostDevice = true;

            Result result = vkSetMoltenVKConfigurationMVK(nint.Zero, config, ref configSize);
            if (result != Result.Success && result != Result.Incomplete) throw new VulkanException(result);

            MVKConfiguration applied = ReadConfiguration();
            GameDiagnostics.Event($"moltenvk_config; async_submit={!(bool)applied.SynchronousQueueSubmits}; previous_sync={previouslySynchronous}; prefill={applied.PrefillMetalCommandBuffers.Value}; max_active_command_buffers={applied.MaxActiveMetalCommandBuffersPerQueue}; semaphore_style={applied.SemaphoreSupportStyle}; fast_math={applied.FastMathEnabled.Value}; argument_buffers={applied.UseMetalArgumentBuffers.Value}; set_result={result}");
            if (applied.SynchronousQueueSubmits)
            {
                Logger.Warning?.PrintMsg(LogClass.Gpu, "MoltenVK did not apply asynchronous queue submission; inspect moltenvk_config in diagnostics.");
            }
        }

        private static string[] Resolver(string path)
        {
            if (path.EndsWith(VulkanLib))
            {
                path = path[..^VulkanLib.Length] + "libMoltenVK.dylib";
                return [path];
            }

            return [];
        }

        public static void InitializeResolver()
        {
            ((DefaultPathResolver)PathResolver.Default).Resolvers.Insert(0, Resolver);
        }
    }
}
