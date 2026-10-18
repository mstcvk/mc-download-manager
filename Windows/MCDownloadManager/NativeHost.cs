using System.Runtime.InteropServices;
using System.Text.Json;

namespace MCDownloadManager;

/// Native messaging host for Chrome, Edge, Brave and Firefox. The browser starts this exe (with the caller's
/// origin as an argument) when the extension calls runtime.sendNativeMessage. It understands one request,
/// {"action": "launchApp"}, which starts the app in the background. Nothing else (URLs, cookies) passes through.
///
/// Protocol: each message is a 32-bit length in native byte order followed by UTF-8 JSON, on stdin/stdout.
static class NativeHost
{
    /// Chrome passes "chrome-extension://<id>/" (plus --parent-window=…); Firefox passes the manifest path and the add-on id.
    public static bool IsInvocation(string[] args) =>
        args.Any(a => a.StartsWith("chrome-extension://", StringComparison.Ordinal))
        || args.Contains(NativeHostRegistry.FirefoxAddonId);

    public static int Run()
    {
        using var stdin = Console.OpenStandardInput();
        using var stdout = Console.OpenStandardOutput();
        // sendNativeMessage sends one message and closes stdin; connectNative keeps it open. Serve until EOF.
        while (ReadMessage(stdin) is { } message)
        {
            var action = message.TryGetProperty("action", out var a) && a.ValueKind == JsonValueKind.String ? a.GetString() : null;
            object reply = action switch
            {
                "launchApp" => new { ok = LaunchApp() },
                "ping" => new { ok = true },
                _ => new { ok = false, error = "unknown action" },
            };
            Write(stdout, reply);
        }
        return 0;
    }

    private static JsonElement? ReadMessage(Stream input)
    {
        var header = new byte[4];
        if (!ReadExactly(input, header)) return null;
        var length = BitConverter.ToUInt32(header);
        if (length == 0 || length > 1 << 20) return null;
        var body = new byte[length];
        if (!ReadExactly(input, body)) return null;
        try { return JsonDocument.Parse(body).RootElement.Clone(); }
        catch (JsonException) { return null; }
    }

    private static bool ReadExactly(Stream s, byte[] buffer)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var n = s.Read(buffer, read, buffer.Length - read);
            if (n == 0) return false;
            read += n;
        }
        return true;
    }

    private static void Write(Stream output, object obj)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(obj);
        output.Write(BitConverter.GetBytes((uint)body.Length));
        output.Write(body);
        output.Flush();
    }

    /// Starts the app in the background; a running app is left as is.
    private static bool LaunchApp()
    {
        if (Program.IsAppRunning()) return true;
        var exe = Environment.ProcessPath;
        if (exe == null || !File.Exists(exe)) return false;
        // Browsers run native hosts inside a job object that is closed with the host; break away from it so the
        // app keeps running after this process exits.
        return StartDetached(exe, "--background", breakaway: true) || StartDetached(exe, "--background", breakaway: false);
    }

    private static bool StartDetached(string exe, string args, bool breakaway)
    {
        const uint DETACHED_PROCESS = 0x00000008, CREATE_BREAKAWAY_FROM_JOB = 0x01000000, CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        var si = new STARTUPINFO { cb = Marshal.SizeOf<STARTUPINFO>() };
        var flags = DETACHED_PROCESS | CREATE_UNICODE_ENVIRONMENT | (breakaway ? CREATE_BREAKAWAY_FROM_JOB : 0);
        var cmd = $"\"{exe}\" {args}";
        if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, Path.GetDirectoryName(exe), ref si, out var pi))
            return false;
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return true;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(string? lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string? lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr h);
}
