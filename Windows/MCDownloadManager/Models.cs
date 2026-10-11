using System.Text.Json.Serialization;

namespace MCDownloadManager;

public enum DownloadKind { File, Video }

public enum DownloadState { Queued, Probing, Downloading, Paused, Completed, Failed, Cancelled }

public static class DownloadStateExtensions
{
    public static bool IsActive(this DownloadState s) => s is DownloadState.Probing or DownloadState.Downloading;

    /// Name used on the bridge (matches the macOS app: "downloading", "paused", …).
    public static string Wire(this DownloadState s) => s.ToString().ToLowerInvariant();

    public static string Label(this DownloadState s) => s switch
    {
        DownloadState.Queued => L.T("Queued", "Sırada"),
        DownloadState.Probing => L.T("Connecting", "Bağlanıyor"),
        DownloadState.Downloading => L.T("Downloading", "İndiriliyor"),
        DownloadState.Paused => L.T("Paused", "Duraklatıldı"),
        DownloadState.Completed => L.T("Completed", "Tamamlandı"),
        DownloadState.Failed => L.T("Error", "Hata"),
        DownloadState.Cancelled => L.T("Cancelled", "İptal edildi"),
        _ => s.ToString(),
    };
}

public sealed class SegmentInfo
{
    public long Start { get; set; }
    public long End { get; set; }          // inclusive
    public long Received { get; set; }

    [JsonIgnore] public long Length => End - Start + 1;
    [JsonIgnore] public bool IsDone => Received >= Length;

    public SegmentInfo Clone() => new() { Start = Start, End = End, Received = Received };
}

public sealed class DownloadItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Url { get; set; } = "";
    public string FileName { get; set; } = "";
    public string Directory { get; set; } = "";
    public DownloadKind Kind { get; set; } = DownloadKind.File;
    public DownloadState State { get; set; } = DownloadState.Queued;
    public long TotalBytes { get; set; } = -1;
    public long ReceivedBytes { get; set; }
    public bool SupportsRanges { get; set; }
    public List<SegmentInfo> Segments { get; set; } = new();
    public Dictionary<string, string> Headers { get; set; } = new();
    public string? CookieFile { get; set; }
    public string? ErrorMessage { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public DateTime? CompletedAt { get; set; }
    public string? FinalPath { get; set; }
    public int RequestedSegments { get; set; }      // 0 = value from settings

    // Not persisted
    [JsonIgnore] public double Speed { get; set; }
    [JsonIgnore] public string Log { get; set; } = "";
    [JsonIgnore] public string Stage { get; set; } = "";   // yt-dlp: current phase

    /// Part file: id-based so it stays the same when the name changes.
    [JsonIgnore] public string PartPath => Path.Combine(Directory, $".dm-{Id}.part");
    [JsonIgnore] public double Progress => TotalBytes > 0 ? Math.Min(1, (double)ReceivedBytes / TotalBytes) : 0;
    [JsonIgnore] public FileCategory Category => FileCategories.Detect(FileName, Kind);
    [JsonIgnore] public Uri Uri => new(Url);
}

public sealed class DownloadFailure(string message) : Exception(message);

public sealed class HttpStatusError(int status)
    : Exception(L.T($"Server returned HTTP {status}", $"Sunucu HTTP {status} döndürdü"))
{
    public int Status { get; } = status;
}

// MARK: - Category

public enum FileCategory { Image, Music, Video, Apps, Document, Compressed, Other }

public static class FileCategories
{
    public static string Label(this FileCategory c) => c switch
    {
        FileCategory.Image => L.T("Images", "Resimler"),
        FileCategory.Music => L.T("Music", "Müzik"),
        FileCategory.Video => L.T("Video", "Video"),
        FileCategory.Apps => L.T("Apps", "Uygulamalar"),
        FileCategory.Document => L.T("Documents", "Belgeler"),
        FileCategory.Compressed => L.T("Archives", "Arşivler"),
        _ => L.T("Other", "Diğer"),
    };

    private static readonly Dictionary<FileCategory, HashSet<string>> Table = new()
    {
        [FileCategory.Image] = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "psd", "ai", "raw", "cr2", "nef", "ico"],
        [FileCategory.Music] = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "alac"],
        [FileCategory.Video] = ["mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m3u8", "3gp"],
        [FileCategory.Apps] = ["dmg", "pkg", "app", "exe", "msi", "msix", "appx", "apk", "ipa", "deb", "rpm", "appimage", "jar", "xpi", "crx"],
        [FileCategory.Document] = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "epub", "mobi", "csv", "md"],
        [FileCategory.Compressed] = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img", "cab"],
    };

    public static FileCategory Detect(string fileName, DownloadKind kind)
    {
        if (kind == DownloadKind.Video) return FileCategory.Video;
        var ext = Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant();
        if (ext.Length == 0) return FileCategory.Other;
        foreach (var (cat, exts) in Table)
            if (exts.Contains(ext)) return cat;
        return FileCategory.Other;
    }
}

/// File types the app captures from the browser. Grouped by category for the settings UI.
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
        var output = new List<string>();
        foreach (var g in Groups)
            if (ids.Contains(g.Id)) output.AddRange(g.Extensions);
        foreach (var token in custom.ToLowerInvariant().Split([',', ' ', ';', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            var e = token.Trim('.', ' ');
            if (e.Length > 0 && !output.Contains(e)) output.Add(e);
        }
        return output;
    }
}
