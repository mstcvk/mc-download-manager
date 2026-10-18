using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace MCDownloadManager;

/// Registers this exe as the native messaging host for Chromium browsers and Firefox, so their extension can
/// start the app when a download arrives while it is not running. On Windows each browser finds the host's
/// manifest through a registry key under HKCU; the manifest names the exe and the extensions allowed to call it.
/// Rewritten at every launch, so moving the app keeps the path current.
public static class NativeHostRegistry
{
    public const string HostName = "com.mesutcevik.mcdownloadmanager";
    public const string FirefoxAddonId = "mc-download-manager@mstcvk.github.io";

    private static readonly string[] ChromiumKeys =
    [
        @"Software\Google\Chrome\NativeMessagingHosts",
        @"Software\Microsoft\Edge\NativeMessagingHosts",
        @"Software\BraveSoftware\Brave-Browser\NativeMessagingHosts",
        @"Software\Chromium\NativeMessagingHosts",
        @"Software\Vivaldi\NativeMessagingHosts",
    ];
    private const string FirefoxKey = @"Software\Mozilla\NativeMessagingHosts";

    private static string ManifestDirectory => Path.Combine(AppSettings.LocalDirectory, "native-host");

    /// Folder the setup dialog copies the extension to; "Load unpacked" points here.
    public static string ExtensionFolder => Path.Combine(AppSettings.LocalDirectory, "Extension");

    /// An unpacked extension without a "key" gets its id from its folder path: the first 128 bits of SHA-256 over
    /// the path (UTF-16LE on Windows, drive letter upper-cased), hex digits mapped 0-f → a-p.
    public static string UnpackedExtensionId(string path)
    {
        path = Path.GetFullPath(path).TrimEnd('\\');
        if (path.Length >= 2 && path[1] == ':') path = char.ToUpperInvariant(path[0]) + path[1..];
        var hash = SHA256.HashData(Encoding.Unicode.GetBytes(path));
        var hex = Convert.ToHexStringLower(hash)[..32];
        return new string(hex.Select(c => (char)('a' + Convert.ToInt32(c.ToString(), 16))).ToArray());
    }

    public static bool IsValidChromiumId(string id) => id.Length == 32 && id.All(c => c is >= 'a' and <= 'p');

    private static List<string> AllowedChromiumIds()
    {
        var ids = AppSettings.Shared.ChromiumExtensionIds.Where(IsValidChromiumId).ToHashSet();
        ids.Add(UnpackedExtensionId(ExtensionFolder));
        return ids.Order().ToList();
    }

    /// Called by the bridge with the id of a Chromium extension that talked to it. Rewrites the manifests when
    /// the id is new (e.g. a store install or a folder somewhere else).
    public static void NoteExtensionId(string id)
    {
        var s = AppSettings.Shared;
        if (!IsValidChromiumId(id) || s.ChromiumExtensionIds.Contains(id)) return;
        s.ChromiumExtensionIds.Add(id);
        s.Save();
        Register();
    }

    public static void Register()
    {
        var exe = Environment.ProcessPath;
        if (exe == null) return;
        try
        {
            Directory.CreateDirectory(ManifestDirectory);
            var chromium = Path.Combine(ManifestDirectory, HostName + ".chromium.json");
            var firefox = Path.Combine(ManifestDirectory, HostName + ".firefox.json");
            WriteIfChanged(chromium, new Dictionary<string, object>
            {
                ["name"] = HostName,
                ["description"] = "MC Download Manager launcher",
                ["path"] = exe,
                ["type"] = "stdio",
                ["allowed_origins"] = AllowedChromiumIds().Select(id => $"chrome-extension://{id}/").ToList(),
            });
            WriteIfChanged(firefox, new Dictionary<string, object>
            {
                ["name"] = HostName,
                ["description"] = "MC Download Manager launcher",
                ["path"] = exe,
                ["type"] = "stdio",
                ["allowed_extensions"] = new[] { FirefoxAddonId },
            });
            foreach (var key in ChromiumKeys) SetDefault(key + "\\" + HostName, chromium);
            SetDefault(FirefoxKey + "\\" + HostName, firefox);
        }
        catch { }
    }

    /// Removes the registry entries (used by --unregister, e.g. before deleting the app).
    public static void Unregister()
    {
        foreach (var key in ChromiumKeys.Append(FirefoxKey))
            try { Registry.CurrentUser.DeleteSubKeyTree(key + "\\" + HostName, throwOnMissingSubKey: false); } catch { }
        try { Directory.Delete(ManifestDirectory, recursive: true); } catch { }
    }

    private static void WriteIfChanged(string path, object manifest)
    {
        var json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });
        if (File.Exists(path) && File.ReadAllText(path) == json) return;
        File.WriteAllText(path, json);
    }

    private static void SetDefault(string subKey, string value)
    {
        using var k = Registry.CurrentUser.CreateSubKey(subKey);
        if (k.GetValue(null) as string != value) k.SetValue(null, value);
    }
}
