using System.Text.Json;
using System.Text.Json.Serialization;

namespace MCDownloadManager;

/// Settings stored as JSON in %APPDATA%\MC Download Manager\settings.json.
public sealed class AppSettings
{
    public static readonly string SupportDirectory =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MC Download Manager");

    /// Machine-local data (installed tools, native host manifests, the unpacked extension).
    public static readonly string LocalDirectory =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MC Download Manager");

    private static string FilePath => Path.Combine(SupportDirectory, "settings.json");

    public static string DefaultDownloadDirectory
    {
        get
        {
            var downloads = KnownFolders.Downloads ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            return Path.Combine(downloads, "MC Download Manager");
        }
    }

    public int SegmentCount { get; set; } = 8;
    public int MaxConcurrent { get; set; } = 3;
    public int ServerPort { get; set; } = 48213;
    public string DownloadDirectory { get; set; } = DefaultDownloadDirectory;
    public string YtdlpPath { get; set; } = "";
    public string VideoFormat { get; set; } = "";        // custom -f (overrides the pickers when non-empty)
    public string VideoContainer { get; set; } = "mp4";  // mp4 | mkv | webm | original
    public int VideoMaxHeight { get; set; } = 1080;      // 0 = best, -1 = audio m4a, -2 = audio mp3
    public bool AutoStart { get; set; } = true;
    public bool NotifyOnComplete { get; set; } = true;
    public bool OrganizeByCategory { get; set; } = true;
    public bool StartMinimized { get; set; } = true;
    public List<string> CaptureGroupIds { get; set; } = [.. CaptureTypes.DefaultGroupIds];
    public string CustomExtensions { get; set; } = "";
    /// Chromium extension ids that talked to the bridge; allowed to call the native host that launches the app.
    public List<string> ChromiumExtensionIds { get; set; } = [];

    [JsonIgnore] public List<string> CaptureExtensions => CaptureTypes.Extensions(CaptureGroupIds, CustomExtensions);

    public static AppSettings Shared { get; } = Load();

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), JsonOptions) ?? new AppSettings();
        }
        catch { /* corrupt file: start with defaults */ }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            System.IO.Directory.CreateDirectory(SupportDirectory);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch { }
    }

    public int ClampedPort => Math.Clamp(ServerPort, 1024, 65535);

    /// yt-dlp arguments for the chosen format/quality.
    public List<string> YtdlpFormatArguments()
    {
        var custom = VideoFormat.Trim();
        if (custom.Length > 0) return ["-f", custom, "--merge-output-format", VideoContainer == "original" ? "mkv" : VideoContainer];
        if (VideoMaxHeight == -1) return ["-f", "ba/b", "-x", "--audio-format", "m4a", "--audio-quality", "0"];
        if (VideoMaxHeight == -2) return ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"];
        var h = VideoMaxHeight > 0 ? $"[height<={VideoMaxHeight}]" : "";
        string expr;
        List<string> args = [];
        switch (VideoContainer)
        {
            case "mp4":
                // Prefer H.264 + AAC so the file plays everywhere; fall back to anything and merge into mp4.
                expr = $"bv*{h}[vcodec^=avc1]+ba[acodec^=mp4a]/bv*{h}[ext=mp4]+ba[ext=m4a]/bv*{h}+ba/b{h}/b";
                args = ["--merge-output-format", "mp4", "--remux-video", "mp4"];
                break;
            case "webm":
                expr = $"bv*{h}[ext=webm]+ba[ext=webm]/bv*{h}+ba/b{h}/b";
                args = ["--merge-output-format", "webm"];
                break;
            case "mkv":
                expr = $"bv*{h}+ba/b{h}/b";
                args = ["--merge-output-format", "mkv"];
                break;
            default:
                expr = $"bv*{h}+ba/b{h}/b";
                break;
        }
        return ["-f", expr, .. args];
    }
}

static class KnownFolders
{
    private static readonly Guid DownloadsId = new("374DE290-123F-4565-9164-39C4925E467B");

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int SHGetKnownFolderPath(ref Guid rfid, uint dwFlags, IntPtr hToken, out IntPtr ppszPath);

    public static string? Downloads
    {
        get
        {
            var id = DownloadsId;
            if (SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out var p) != 0) return null;
            try { return System.Runtime.InteropServices.Marshal.PtrToStringUni(p); }
            finally { System.Runtime.InteropServices.Marshal.FreeCoTaskMem(p); }
        }
    }
}
