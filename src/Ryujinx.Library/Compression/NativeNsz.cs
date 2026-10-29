using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Library
{
    // A synchronous C ABI: the caller owns paths/context for the whole call.
    // Returning nonzero from progress cancels, without sharing mutable raw memory.
    public static unsafe class NszNative
    {
        [ThreadStatic]
        private static string _lastError;

        [ThreadStatic]
        private static string _lastSha256;

        [UnmanagedCallersOnly(EntryPoint = "nsz_decompress_to_nsp", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static int Decompress(byte* sourceUtf8, byte* destinationUtf8, long availableBytes,
            delegate* unmanaged[Cdecl]<void*, long, long, int> progress, void* context)
        {
            _lastError = null;
            _lastSha256 = null;
            try
            {
                string source = Marshal.PtrToStringUTF8((IntPtr)sourceUtf8);
                string destination = Marshal.PtrToStringUTF8((IntPtr)destinationUtf8);
                if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(destination))
                {
                    throw new ArgumentException("NSZ 源路径或目标路径无效。");
                }

                _lastSha256 = NszDecompressor.Decompress(source, destination, availableBytes, (written, total) =>
                {
                    if (progress != null && progress(context, written, total) != 0)
                    {
                        throw new OperationCanceledException();
                    }
                });
                return 0;
            }
            catch (OperationCanceledException)
            {
                _lastError = "已取消 NSZ 解压。";
                return 1;
            }
            catch (Exception exception)
            {
                _lastError = exception.Message;
                return -1;
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "nsz_get_last_sha256", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static IntPtr GetLastSha256() => _lastSha256 == null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(_lastSha256);

        [UnmanagedCallersOnly(EntryPoint = "nsz_get_last_error", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static IntPtr GetLastError()
        {
            return Marshal.StringToCoTaskMemUTF8(_lastError ?? "NSZ 解压失败。");
        }

        [UnmanagedCallersOnly(EntryPoint = "nsz_free_string", CallConvs = new[] { typeof(CallConvCdecl) })]
        public static void FreeString(IntPtr pointer)
        {
            if (pointer != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(pointer);
            }
        }
    }
}
