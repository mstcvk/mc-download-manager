using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MCDM;

/// User settings, stored as JSON in %APPDATA%\MC Download Manager\settings.json. Every change is saved at once.
public sealed class AppSettings : INotifyPropertyChanged
{
    public static readonly string SupportDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MC Download Manager");
    static readonly string FilePath = Path.Combine(SupportDir, "settings.json");

    public static AppSettings Shared { get; } = Load();

    int segmentCount = 8, maxConcurrent = 3, serverPort = 48213, videoMaxHeight = 1080;
    string downloadDirectory = DefaultDownloadDir, ytdlpPath = "", videoFormat = "", videoContainer = "mp4", customExtensions = "";
    bool autoStart = true, notifyOnComplete = true, showDetailOnStart = true, autoCloseDetail, watchClipboard = true,
         onboardingDone, organizeByCategory = true, checkForUpdates = true, startInTray = true, loginItemAutoRegistered, denoPromptSuppressed;
    List<string> captureGroupIds = [.. CaptureTypes.DefaultGroupIds];

    public int SegmentCount { get => segmentCount; set => Set(ref segmentCount, value); }
    public int MaxConcurrent { get => maxConcurrent; set => Set(ref maxConcurrent, value); }
    public int ServerPort { get => serverPort; set => Set(ref serverPort, value); }
    public string DownloadDirectory { get => downloadDirectory; set => Set(ref downloadDirectory, value); }
    public string YtdlpPath { get => ytdlpPath; set => Set(ref ytdlpPath, value); }
    /// custom -f (overrides pickers when non-empty)
    public string VideoFormat { get => videoFormat; set => Set(ref videoFormat, value); }
    /// mp4 | mkv | webm | original
    public string VideoContainer { get => videoContainer; set => Set(ref videoContainer, value); }
    /// 0 = best, -1 = audio m4a, -2 = audio mp3
    public int VideoMaxHeight { get => videoMaxHeight; set => Set(ref videoMaxHeight, value); }
    public bool AutoStart { get => autoStart; set => Set(ref autoStart, value); }
    public bool NotifyOnComplete { get => notifyOnComplete; set => Set(ref notifyOnComplete, value); }
    public bool ShowDetailOnStart { get => showDetailOnStart; set => Set(ref showDetailOnStart, value); }
    public bool AutoCloseDetail { get => autoCloseDetail; set => Set(ref autoCloseDetail, value); }
    public bool WatchClipboard { get => watchClipboard; set => Set(ref watchClipboard, value); }
    public List<string> CaptureGroupIds { get => captureGroupIds; set => Set(ref captureGroupIds, value); }
    public string CustomExtensions { get => customExtensions; set => Set(ref customExtensions, value); }
    public bool OnboardingDone { get => onboardingDone; set => Set(ref onboardingDone, value); }
    public bool OrganizeByCategory { get => organizeByCategory; set => Set(ref organizeByCategory, value); }
    public bool CheckForUpdates { get => checkForUpdates; set => Set(ref checkForUpdates, value); }
    /// Keep the main window closed at launch; the app is reachable from the tray icon.
    public bool StartInTray { get => startInTray; set => Set(ref startInTray, value); }
    /// One-shot flag: the login item was registered automatically after setup.
    public bool LoginItemAutoRegistered { get => loginItemAutoRegistered; set => Set(ref loginItemAutoRegistered, value); }
    /// The user chose "Don't ask again" on the deno install prompt for YouTube downloads.
    public bool DenoPromptSuppressed { get => denoPromptSuppressed; set => Set(ref denoPromptSuppressed, value); }

    // Bookkeeping that is not shown in the UI
    public List<string> ChromiumExtensionIds { get; set; } = [];
    public DateTime? LastUpdateCheck { get; set; }
    public string? SkippedVersion { get; set; }

    /// All file extensions (lowercase, no dot) the app should capture.
    [JsonIgnore] public List<string> CaptureExtensions => CaptureTypes.Extensions(CaptureGroupIds, CustomExtensions);

    public static string DefaultDownloadDir => Path.Combine(KnownFolders.Downloads, "MC Download Manager");

    /// yt-dlp arguments for the chosen format/quality.
    [JsonIgnore]
    public string[] YtdlpFormatArguments
    {
        get
        {
            var custom = VideoFormat.Trim();
            if (custom.Length > 0) return ["-f", custom, "--merge-output-format", VideoContainer == "original" ? "mkv" : VideoContainer];
            if (VideoMaxHeight == -1) return ["-f", "ba/b", "-x", "--audio-format", "m4a", "--audio-quality", "0"];
            if (VideoMaxHeight == -2) return ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"];
            var h = VideoMaxHeight > 0 ? $"[height<={VideoMaxHeight}]" : "";
            return VideoContainer switch
            {
                // Prefer H.264 + AAC so the file plays everywhere; fall back to anything and merge into mp4.
                "mp4" => ["-f", $"bv*{h}[vcodec^=avc1]+ba[acodec^=mp4a]/bv*{h}[ext=mp4]+ba[ext=m4a]/bv*{h}+ba/b{h}/b",
                          "--merge-output-format", "mp4", "--remux-video", "mp4"],
                "webm" => ["-f", $"bv*{h}[ext=webm]+ba[ext=webm]/bv*{h}+ba/b{h}/b", "--merge-output-format", "webm"],
                "mkv" => ["-f", $"bv*{h}+ba/b{h}/b", "--merge-output-format", "mkv"],
                _ => ["-f", $"bv*{h}+ba/b{h}/b"],
            };
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    bool loading = true;

    void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        if (loading) return;
        Save();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    /// Lists are mutated in place by the UI; call this afterwards.
    public void Touch(string name)
    {
        Save();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    static AppSettings Load()
    {
        AppSettings s;
        try { s = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch { s = new(); }
        s.loading = false;
        return s;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SupportDir);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, FilePath, true);
        }
        catch { }
    }
}

public static class KnownFolders
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint flags, IntPtr token, out string path);

    /// The user's Downloads folder (follows a relocated folder, unlike %USERPROFILE%\Downloads).
    public static string Downloads
    {
        get
        {
            try
            {
                if (SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out var p) == 0) return p;
            }
            catch { }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }
    }
}
