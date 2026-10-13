using System.ComponentModel;
using System.Text.Json.Serialization;

namespace MCDM;

[JsonConverter(typeof(JsonStringEnumConverter<DownloadKind>))]
public enum DownloadKind { File, Video }

[JsonConverter(typeof(JsonStringEnumConverter<DownloadState>))]
public enum DownloadState { Queued, Probing, Downloading, Paused, Completed, Failed, Cancelled }

public static class DownloadStateExt
{
    public static bool IsActive(this DownloadState s) => s is DownloadState.Probing or DownloadState.Downloading;

    /// Wire name used by the bridge (/downloads), same as the macOS app.
    public static string Raw(this DownloadState s) => s.ToString().ToLowerInvariant();

    public static string Label(this DownloadState s) => s switch
    {
        DownloadState.Queued => L.T("Queued"),
        DownloadState.Probing => L.T("Connecting"),
        DownloadState.Downloading => L.T("Downloading"),
        DownloadState.Paused => L.T("Paused"),
        DownloadState.Completed => L.T("Completed"),
        DownloadState.Failed => L.T("Error"),
        _ => L.T("Cancelled"),
    };
}

public sealed class SegmentInfo
{
    public long Start { get; set; }
    public long End { get; set; }          // inclusive
    public long Received { get; set; }

    [JsonIgnore] public long Length => End - Start + 1;
    [JsonIgnore] public bool IsDone => Received >= Length;
    public SegmentInfo Clone() => (SegmentInfo)MemberwiseClone();
}

public sealed class DownloadItem : INotifyPropertyChanged
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Uri Url { get; set; } = new("about:blank");
    public string FileName { get; set; } = "";
    public string Directory { get; set; } = "";
    public DownloadKind Kind { get; set; } = DownloadKind.File;
    public DownloadState State { get; set; } = DownloadState.Queued;
    public long TotalBytes { get; set; } = -1;
    public long ReceivedBytes { get; set; }
    public bool SupportsRanges { get; set; }
    public List<SegmentInfo> Segments { get; set; } = [];
    public Dictionary<string, string> Headers { get; set; } = [];
    public string? CookieFile { get; set; }
    public string? ErrorMessage { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public DateTime? CompletedAt { get; set; }
    public string? FinalPath { get; set; }
    public int RequestedSegments { get; set; }      // 0 = value from settings

    // Not persisted
    [JsonIgnore] public double Speed { get; set; }
    [JsonIgnore] public string Log { get; set; } = "";
    [JsonIgnore] public string Stage { get; set; } = "";   // yt-dlp: current phase (downloading video/audio, merging…)

    /// Part file: id based so it stays stable when the name changes.
    [JsonIgnore] public string PartPath => Path.Combine(Directory, $".dm-{Id}.part");
    [JsonIgnore] public double Progress => TotalBytes > 0 ? Math.Min(1, (double)ReceivedBytes / TotalBytes) : 0;
    [JsonIgnore] public double? Eta => TotalBytes > 0 && Speed > 1 ? (TotalBytes - ReceivedBytes) / Speed : null;
    [JsonIgnore] public FileCategory Category => FileCategories.Detect(FileName, Kind);
    [JsonIgnore] public bool IsFinished => State == DownloadState.Completed;

    // Display helpers for bindings
    [JsonIgnore] public string CategoryLabel => Category.Label();
    [JsonIgnore] public string Glyph => Category.Glyph();
    [JsonIgnore] public string SizeText => TotalBytes > 0 ? Fmt.Size(TotalBytes) : ReceivedBytes > 0 ? Fmt.Size(ReceivedBytes) : "—";
    [JsonIgnore] public string SpeedText => State == DownloadState.Downloading && Speed > 0 ? Fmt.Speed(Speed) : "";
    [JsonIgnore] public string EtaText => State == DownloadState.Downloading && Eta is double e ? Fmt.Duration(e) : "";
    [JsonIgnore] public string AddedText => Fmt.Relative(CreatedAt);
    [JsonIgnore] public bool IsFailed => State == DownloadState.Failed;
    [JsonIgnore] public bool ShowsBar => State is DownloadState.Downloading or DownloadState.Paused or DownloadState.Probing
                                         || (State == DownloadState.Queued && ReceivedBytes > 0);

    /// Status column: percentage + state text.
    [JsonIgnore]
    public string StatusText
    {
        get
        {
            switch (State)
            {
                case DownloadState.Completed: return L.T("Completed");
                case DownloadState.Queued: return L.T("Added");
                case DownloadState.Failed: return L.T("Error: %@", ErrorMessage ?? "");
                case DownloadState.Cancelled: return L.T("Cancelled");
                default:
                    var pct = TotalBytes > 0 ? $"{(int)(Progress * 100)}% " : "";
                    if (Kind == DownloadKind.Video && State == DownloadState.Downloading && Stage.Length > 0) return pct + Stage;
                    return pct + State.Label();
            }
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    /// Every display property derives from the stored fields, so one "everything changed" event refreshes bindings.
    public void Changed() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
}

public sealed class DownloadFailure(string message) : Exception(message);

public sealed class HttpStatusError(int status) : Exception(L.T("Server returned HTTP %lld", status))
{
    public int Status => status;
}

// MARK: - Category

public enum FileCategory { Image, Music, Video, Apps, Document, Compressed, Other }

public static class FileCategories
{
    public static FileCategory[] All => Enum.GetValues<FileCategory>();

    public static string Label(this FileCategory c) => c switch
    {
        FileCategory.Image => L.T("Images"),
        FileCategory.Music => L.T("Music"),
        FileCategory.Video => L.T("Video"),
        FileCategory.Apps => L.T("Apps"),
        FileCategory.Document => L.T("Documents"),
        FileCategory.Compressed => L.T("Archives"),
        _ => L.T("Other"),
    };

    /// Segoe Fluent Icons glyphs.
    public static string Glyph(this FileCategory c) => c switch
    {
        FileCategory.Image => "",
        FileCategory.Music => "",
        FileCategory.Video => "",
        FileCategory.Apps => "",
        FileCategory.Document => "",
        FileCategory.Compressed => "",
        _ => "",
    };

    static readonly (FileCategory Cat, HashSet<string> Exts)[] Table =
    [
        (FileCategory.Image, ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "psd", "ai", "raw", "cr2", "nef", "ico"]),
        (FileCategory.Music, ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "alac"]),
        (FileCategory.Video, ["mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m3u8", "3gp"]),
        (FileCategory.Apps, ["dmg", "pkg", "app", "exe", "msi", "msix", "appx", "apk", "ipa", "deb", "rpm", "appimage", "jar", "xpi", "crx"]),
        (FileCategory.Document, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "epub", "mobi", "csv", "md", "pages", "numbers", "key"]),
        (FileCategory.Compressed, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img", "cab"]),
    ];

    public static FileCategory Detect(string fileName, DownloadKind kind)
    {
        if (kind == DownloadKind.Video) return FileCategory.Video;
        var ext = Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant();
        if (ext.Length == 0) return FileCategory.Other;
        foreach (var (cat, exts) in Table) if (exts.Contains(ext)) return cat;
        return FileCategory.Other;
    }
}

/// File types the app captures (browser downloads, clipboard links). Grouped by category for the UI.
public static class CaptureTypes
{
    public sealed record Group(string Id, FileCategory Category, string[] Extensions);

    public static readonly Group[] Groups =
    [
        new("compressed", FileCategory.Compressed, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img", "cab"]),
        new("apps", FileCategory.Apps, ["exe", "msi", "msix", "appx", "dmg", "pkg", "apk", "ipa", "deb", "rpm", "appimage", "jar", "bin"]),
        new("video", FileCategory.Video, ["mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "mpg", "mpeg", "m3u8", "3gp"]),
        new("music", FileCategory.Music, ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff"]),
        new("document", FileCategory.Document, ["pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "csv"]),
        new("image", FileCategory.Image, ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "psd", "svg", "raw"]),
    ];

    /// Categories enabled by default on first launch.
    public static readonly string[] DefaultGroupIds = ["compressed", "apps", "video", "music", "document"];

    public static List<string> Extensions(IEnumerable<string> groupIds, string custom)
    {
        var ids = groupIds.ToHashSet();
        var output = Groups.Where(g => ids.Contains(g.Id)).SelectMany(g => g.Extensions).ToList();
        foreach (var token in custom.ToLowerInvariant().Split([',', ' ', ';', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            var e = token.Trim('.', ' ');
            if (e.Length > 0 && !output.Contains(e)) output.Add(e);
        }
        return output;
    }

    public static bool Matches(Uri url, List<string> extensions)
    {
        var ext = Path.GetExtension(url.AbsolutePath).TrimStart('.').ToLowerInvariant();
        return ext.Length > 0 && extensions.Contains(ext);
    }
}

public static class Fmt
{
    /// Decimal units like the macOS ByteCountFormatter (.file).
    public static string Size(long n)
    {
        if (n < 0) return "?";
        if (n < 1000) return $"{n} B";
        string[] units = ["KB", "MB", "GB", "TB"];
        double v = n;
        int u = -1;
        do { v /= 1000; u++; } while (v >= 1000 && u < units.Length - 1);
        return u == 0 ? $"{v:0} {units[u]}" : u == 1 ? $"{v:0.0} {units[u]}" : $"{v:0.00} {units[u]}";
    }

    public static string Speed(double bps) => L.T("%@/s", Size((long)bps));

    public static string Duration(double t)
    {
        var s = (long)Math.Round(t);
        if (s < 60) return L.T("%lld s", s);
        if (s < 3600) return L.T("%lld min %lld s", s / 60, s % 60);
        return L.T("%lld h %lld min", s / 3600, s % 3600 / 60);
    }

    public static string Relative(DateTime d)
    {
        var span = DateTime.Now - d;
        if (span.TotalMinutes < 1) return L.T("just now");
        if (d.Date == DateTime.Today) return d.ToString("t");
        if (d.Date == DateTime.Today.AddDays(-1)) return L.T("yesterday") + " " + d.ToString("t");
        return d.ToString("g");
    }
}
