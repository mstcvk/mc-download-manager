using System.Diagnostics;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace MCDM;

public enum BrowserKind { Chrome, Edge, Brave, Firefox }

/// Browser extension helpers. Supported browsers for the guided setup: Google Chrome, Microsoft Edge, Brave, Firefox.
public static class BrowserIntegration
{
    public static readonly BrowserKind[] All = Enum.GetValues<BrowserKind>();

    extension(BrowserKind kind)
    {
        public string Name => kind switch
        {
            BrowserKind.Chrome => "Google Chrome",
            BrowserKind.Edge => "Microsoft Edge",
            BrowserKind.Brave => "Brave",
            _ => "Firefox",
        };
        /// Key used by the bridge / extension (X-MCDM-Extension).
        public string Id => kind.ToString().ToLowerInvariant();
        public string ExeName => kind switch
        {
            BrowserKind.Chrome => "chrome.exe",
            BrowserKind.Edge => "msedge.exe",
            BrowserKind.Brave => "brave.exe",
            _ => "firefox.exe",
        };
        public string ExtensionsPageUrl => kind switch
        {
            BrowserKind.Chrome => "chrome://extensions",
            BrowserKind.Edge => "edge://extensions",
            BrowserKind.Brave => "brave://extensions",
            _ => "about:addons",
        };
        public bool IsChromium => kind != BrowserKind.Firefox;
        public string? ExePath => FindExe(kind.ExeName);
        public bool IsInstalled => kind.ExePath != null;
        public ImageSource? Icon => IconFor(kind.ExePath);
    }

    /// Installed browsers in setup order.
    public static List<BrowserKind> InstalledBrowsers => All.Where(k => k.IsInstalled).ToList();

    /// Browsers register their exe under App Paths (per machine or per user).
    static string? FindExe(string exe)
    {
        foreach (var root in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var k = root.OpenSubKey($@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{exe}");
                if (k?.GetValue(null) is string p && File.Exists(p.Trim('"'))) return p.Trim('"');
            }
            catch { }
        }
        return null;
    }

    static ImageSource? IconFor(string? exe)
    {
        if (exe == null) return null;
        try
        {
            using var icon = System.Drawing.Icon.ExtractAssociatedIcon(exe);
            if (icon == null) return null;
            var src = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, System.Windows.Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        catch { return null; }
    }

    // MARK: Files

    /// Unpacked extension shipped next to the app.
    public static string BundledExtensionFolder =>
        Environment.GetEnvironmentVariable("MCDM_EXTENSION_DIR") ?? Path.Combine(AppContext.BaseDirectory, "Extension");

    /// Downloads\MC Download Manager\Browser Plugins
    public static string PluginsRoot => Path.Combine(AppSettings.DefaultDownloadDir, "Browser Plugins");

    public static string PluginFolder(BrowserKind kind) => Path.Combine(PluginsRoot, kind.Name);

    /// Copies the unpacked extension into the browser's plugin folder. Returns the folder.
    public static string PrepareFiles(BrowserKind kind)
    {
        var dest = PluginFolder(kind);
        Directory.CreateDirectory(PluginsRoot);
        if (Directory.Exists(dest)) Directory.Delete(dest, true);
        CopyDirectory(BundledExtensionFolder, dest);
        var readme = $"""
            MC Download Manager — {kind.Name} extension

            1. Open {kind.ExtensionsPageUrl} in {kind.Name}.
            2. Turn on "Developer mode".
            3. Click "Load unpacked" and select this folder.

            Do not move or delete this folder while the extension is installed.
            """;
        try { File.WriteAllText(Path.Combine(dest, "README.txt"), readme); } catch { }
        Task.Run(NativeHost.Register);   // the folder's extension id may call the native host
        return dest;
    }

    static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)), true);
        foreach (var d in Directory.GetDirectories(from)) CopyDirectory(d, Path.Combine(to, Path.GetFileName(d)));
    }

    public static bool FilesPrepared(BrowserKind kind) => File.Exists(Path.Combine(PluginFolder(kind), "manifest.json"));

    // MARK: Opening pages

    /// Opens the browser's extensions page (internal pages such as chrome://extensions only open from the command line).
    public static void OpenExtensionsPage(BrowserKind kind) => OpenIn(kind, kind.ExtensionsPageUrl);

    static void OpenIn(BrowserKind kind, string address)
    {
        if (kind.ExePath is not { } exe) return;
        try { Process.Start(new ProcessStartInfo(exe) { ArgumentList = { address }, UseShellExecute = false }); } catch { }
    }

    // MARK: Firefox

    /// Add-on signed by Mozilla (unlisted channel), placed next to the exe by scripts/build.ps1. Release Firefox installs
    /// it permanently when the file is opened: Firefox shows its own "Add …?" prompt.
    public static string? SignedFirefoxAddon => Bundled("FirefoxExtension.xpi");
    /// Unsigned build, only loadable temporarily via about:debugging (removed when Firefox quits).
    public static string? UnsignedFirefoxAddon => Bundled("FirefoxExtension-unsigned.xpi");

    static string? Bundled(string name)
    {
        var p = Path.Combine(AppContext.BaseDirectory, name);
        return File.Exists(p) ? p : null;
    }

    /// Hands the signed add-on to Firefox, which asks the user to confirm the installation.
    public static void InstallFirefoxAddon()
    {
        if (SignedFirefoxAddon is { } xpi) OpenIn(BrowserKind.Firefox, xpi);
    }

    /// Copies the unsigned add-on next to the other browser plugins for a temporary load.
    public static string PrepareTemporaryFirefoxAddon()
    {
        var src = UnsignedFirefoxAddon ?? throw new FileNotFoundException("FirefoxExtension-unsigned.xpi");
        var dir = PluginFolder(BrowserKind.Firefox);
        Directory.CreateDirectory(dir);
        var dest = Path.Combine(dir, "mc-download-manager.xpi");
        File.Copy(src, dest, true);
        return dest;
    }

    public static void OpenFirefoxDebugging() => OpenIn(BrowserKind.Firefox, "about:debugging#/runtime/this-firefox");

    public static void RevealInExplorer(string path)
    {
        try
        {
            if (File.Exists(path)) Process.Start("explorer.exe", $"/select,\"{path}\"");
            else { Directory.CreateDirectory(path); Shell.Open(path); }
        }
        catch { }
    }
}
