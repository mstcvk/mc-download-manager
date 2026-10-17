using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace MCDM;

/// Native messaging for Chrome, Edge, Brave and Firefox. The browser starts this exe (with the extension origin or the
/// Firefox add-on id as argument) when the extension calls runtime.sendNativeMessage; it understands one request,
/// {"action": "launchApp"}, which starts MC Download Manager in the background so the extension can hand over a
/// download while the app was not running. Nothing else (URLs, cookies) passes through here.
///
/// Registration: each browser reads HKCU\Software\…\NativeMessagingHosts\<name>, whose default value points to a
/// manifest naming this exe and the extensions allowed to call it. Rewritten at every launch, so moving the app keeps
/// the path current.
public static class NativeHost
{
    public const string HostName = "com.mesutcevik.mcdownloadmanager";
    public const string FirefoxAddonId = "mc-download-manager@mstcvk.github.io";

    static readonly string[] ChromiumKeys =
    [
        @"Software\Google\Chrome\NativeMessagingHosts",
        @"Software\Microsoft\Edge\NativeMessagingHosts",
        @"Software\BraveSoftware\Brave-Browser\NativeMessagingHosts",
        @"Software\Chromium\NativeMessagingHosts",
    ];
    const string FirefoxKey = @"Software\Mozilla\NativeMessagingHosts";

    /// Chrome passes "chrome-extension://<id>/" as the first argument; Firefox passes the manifest path and the add-on id.
    public static bool IsHostInvocation(string[] args) =>
        args.Length > 0 && (args[0].StartsWith("chrome-extension://", StringComparison.OrdinalIgnoreCase) || args.Contains(FirefoxAddonId));

    // MARK: - Host mode

    /// Protocol: each message is a 32-bit length in native byte order followed by UTF-8 JSON, on stdin/stdout.
    /// sendNativeMessage sends one message and closes stdin; connectNative keeps it open. Serve until EOF.
    public static int Serve()
    {
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();
        while (Read(input) is { } message)
        {
            object reply = (message["action"] as JsonValue)?.GetValue<string>() switch
            {
                "launchApp" => new { ok = LaunchApp() },
                "ping" => new { ok = true },
                _ => new { ok = false, error = "unknown action" },
            };
            var body = JsonSerializer.SerializeToUtf8Bytes(reply);
            output.Write(BitConverter.GetBytes(body.Length));
            output.Write(body);
            output.Flush();
        }
        return 0;
    }

    static JsonObject? Read(Stream input)
    {
        var header = new byte[4];
        if (!ReadExactly(input, header)) return null;
        int length = BitConverter.ToInt32(header);
        if (length <= 0 || length > 1 << 20) return null;
        var body = new byte[length];
        if (!ReadExactly(input, body)) return null;
        try { return JsonNode.Parse(body) as JsonObject; } catch { return null; }
    }

    static bool ReadExactly(Stream s, byte[] buffer)
    {
        try { s.ReadExactly(buffer); return true; }
        catch { return false; }
    }

    /// Starts the app in the tray; a running instance is left as is (single-instance check in Program).
    static bool LaunchApp()
    {
        try
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--background") { UseShellExecute = false });
            return true;
        }
        catch { return false; }
    }

    // MARK: - Registration

    /// An unpacked extension without a "key" gets its id from its folder path: the first 128 bits of SHA-256 over the
    /// path (UTF-16LE on Windows, drive letter upper-cased), hex digits mapped 0-f → a-p. Known in advance for the folders
    /// the setup wizard prepares.
    public static string UnpackedExtensionId(string path)
    {
        if (path.Length >= 2 && path[1] == ':') path = char.ToUpperInvariant(path[0]) + path[1..];
        var hash = SHA256.HashData(Encoding.Unicode.GetBytes(path));
        return new string(Convert.ToHexStringLower(hash)[..32].Select(c => (char)('a' + Convert.ToInt32(c.ToString(), 16))).ToArray());
    }

    public static bool IsValidChromiumId(string id) => id.Length == 32 && id.All(c => c is >= 'a' and <= 'p');

    static List<string> AllowedChromiumIds()
    {
        var ids = AppSettings.Shared.ChromiumExtensionIds.ToHashSet();
        foreach (var kind in BrowserIntegration.All.Where(k => k.IsChromium))
            ids.Add(UnpackedExtensionId(BrowserIntegration.PluginFolder(kind)));
        return ids.Order().ToList();
    }

    /// Called by the bridge with the id of a Chromium extension that talked to it. Rewrites the manifests when the id
    /// is new (e.g. a store install or a folder in another place).
    public static void NoteExtensionId(string id)
    {
        var s = AppSettings.Shared;
        if (!IsValidChromiumId(id) || s.ChromiumExtensionIds.Contains(id)) return;
        s.ChromiumExtensionIds.Add(id);
        s.Save();
        Task.Run(Register);
    }

    /// Writes both manifests and points every browser's registry key at them.
    public static void Register()
    {
        try
        {
            var dir = Path.Combine(AppSettings.SupportDir, "NativeMessagingHosts");
            Directory.CreateDirectory(dir);
            var exe = Environment.ProcessPath!;
            var chromium = Path.Combine(dir, "chromium.json");
            var firefox = Path.Combine(dir, "firefox.json");
            WriteIfChanged(chromium, new JsonObject
            {
                ["name"] = HostName, ["description"] = "MC Download Manager launcher", ["path"] = exe, ["type"] = "stdio",
                ["allowed_origins"] = new JsonArray(AllowedChromiumIds().Select(i => (JsonNode)$"chrome-extension://{i}/").ToArray()),
            });
            WriteIfChanged(firefox, new JsonObject
            {
                ["name"] = HostName, ["description"] = "MC Download Manager launcher", ["path"] = exe, ["type"] = "stdio",
                ["allowed_extensions"] = new JsonArray(FirefoxAddonId),
            });
            foreach (var key in ChromiumKeys) SetDefault($@"{key}\{HostName}", chromium);
            SetDefault($@"{FirefoxKey}\{HostName}", firefox);
        }
        catch { }
    }

    static void WriteIfChanged(string path, JsonObject manifest)
    {
        var text = manifest.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        if (File.Exists(path) && File.ReadAllText(path) == text) return;
        File.WriteAllText(path, text);
    }

    static void SetDefault(string subKey, string value)
    {
        using var k = Registry.CurrentUser.CreateSubKey(subKey);
        if (k.GetValue(null) as string != value) k.SetValue(null, value);
    }
}
