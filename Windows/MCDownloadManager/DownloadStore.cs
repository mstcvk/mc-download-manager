using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace MCDownloadManager;

public sealed record BrowserCookie(string Name, string Value, string Domain, string Path, bool Secure, long ExpirationDate);

public sealed class NewDownloadRequest(Uri url)
{
    public Uri Url { get; } = url;
    public string? FileName { get; set; }
    public string? Referer { get; set; }
    public string? UserAgent { get; set; }
    public string? CookieHeader { get; set; }
    public List<BrowserCookie> Cookies { get; } = [];
    public Dictionary<string, string> ExtraHeaders { get; } = new();
    public DownloadKind Kind { get; set; } = DownloadKind.File;
    public int? Segments { get; set; }
}

/// The download list, queue and persistence. Single-threaded: every public member is called on the UI thread;
/// downloader callbacks are posted back to it.
public sealed class DownloadStore
{
    public const string DefaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

    public List<DownloadItem> Items { get; private set; } = [];
    public event Action? Changed;
    public event Action<DownloadItem>? Completed;

    private readonly AppSettings _settings;
    private readonly SynchronizationContext _ui;
    private readonly Dictionary<Guid, SegmentedDownloader> _downloaders = new();
    private readonly Dictionary<Guid, Process> _videoProcesses = new();
    private readonly Dictionary<Guid, (long Base, long LastDownloaded, long ApproxTotal)> _videoPhase = new();
    private readonly HashSet<Guid> _cookielessVideos = [];
    private readonly Dictionary<Guid, (long Bytes, DateTime Time)> _samples = new();
    private readonly System.Windows.Forms.Timer _ticker = new() { Interval = 500 };
    private readonly System.Windows.Forms.Timer _saveTimer = new() { Interval = 500 };
    private int _tickCount;

    private static string StorePath => Path.Combine(AppSettings.SupportDirectory, "downloads.json");
    private static readonly JsonSerializerOptions JsonOptions = new() { Converters = { new JsonStringEnumConverter() } };

    public DownloadStore(AppSettings settings, SynchronizationContext ui)
    {
        _settings = settings;
        _ui = ui;
        Directory.CreateDirectory(AppSettings.SupportDirectory);
        Load();
        _ticker.Tick += (_, _) => Tick();
        _ticker.Start();
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); Save(); };
    }

    public int ActiveCount => Items.Count(i => i.State.IsActive());

    private DownloadItem? Find(Guid id) => Items.FirstOrDefault(i => i.Id == id);

    private void Update(Guid id, Action<DownloadItem> change)
    {
        if (Find(id) is not { } item) return;
        change(item);
        Changed?.Invoke();
    }

    private void Post(Action a) => _ui.Post(_ => a(), null);

    public string DestinationDirectory(DownloadItem item) =>
        _settings.OrganizeByCategory ? Path.Combine(item.Directory, item.Category.Label()) : item.Directory;

    // MARK: - Adding

    public DownloadItem Add(NewDownloadRequest req)
    {
        var headers = new Dictionary<string, string>(req.ExtraHeaders, StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(req.Referer)) headers["Referer"] = req.Referer;
        if (!string.IsNullOrEmpty(req.UserAgent)) headers["User-Agent"] = req.UserAgent;
        if (!string.IsNullOrEmpty(req.CookieHeader)) headers["Cookie"] = req.CookieHeader;
        if (!headers.ContainsKey("User-Agent")) headers["User-Agent"] = DefaultUserAgent;

        var name = string.IsNullOrEmpty(req.FileName) ? FileNameFrom(req.Url) : req.FileName;
        if (req.Kind == DownloadKind.Video) name = req.Url.Host;
        var item = new DownloadItem
        {
            Url = req.Url.AbsoluteUri,
            FileName = Sanitize(name),
            Directory = _settings.DownloadDirectory,
            Kind = req.Kind,
            Headers = headers,
            RequestedSegments = req.Segments ?? 0,
        };
        if (req.Kind == DownloadKind.Video && req.Cookies.Count > 0)
            item.CookieFile = WriteCookieFile(req.Cookies, item.Id);
        try { Directory.CreateDirectory(item.Directory); } catch { }
        Items.Insert(0, item);
        ScheduleSave();
        Changed?.Invoke();
        if (_settings.AutoStart) PumpQueue();
        return item;
    }

    public void AddUrls(string text, DownloadKind kind)
    {
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (Uri.TryCreate(line.Trim(), UriKind.Absolute, out var url) && (url.Scheme == Uri.UriSchemeHttp || url.Scheme == Uri.UriSchemeHttps))
                Add(new NewDownloadRequest(url) { Kind = kind });
        }
    }

    // MARK: - Queue

    public void PumpQueue()
    {
        var slots = Math.Max(0, _settings.MaxConcurrent - ActiveCount);
        foreach (var item in Items.AsEnumerable().Reverse().Where(i => i.State == DownloadState.Queued).ToList())
        {
            if (slots <= 0) break;
            if (item.Kind == DownloadKind.Video) StartVideo(item); else StartFile(item);
            slots--;
        }
    }

    private void StartFile(DownloadItem item)
    {
        var resumable = item.SupportsRanges && item.TotalBytes > 0 && item.Segments.Count > 0 && File.Exists(item.PartPath);
        var dl = new SegmentedDownloader(new SegmentedDownloader.Configuration(
            item.Uri, item.Headers, item.PartPath,
            item.RequestedSegments > 0 ? item.RequestedSegments : _settings.SegmentCount)
        {
            ResumeSegments = resumable ? item.Segments : null,
            ResumeTotal = resumable ? item.TotalBytes : -1,
        });
        var id = item.Id;
        dl.OnProbe = probe => Post(() => { if (Current(id, dl)) HandleProbe(id, probe); });
        dl.OnProgress = (received, segs) => Post(() =>
        {
            if (!Current(id, dl)) return;
            if (Find(id) is not { } it) return;
            it.ReceivedBytes = received;
            if (segs.Count > 0) it.Segments = segs;
            if (it.State == DownloadState.Probing) it.State = DownloadState.Downloading;
        });
        dl.OnFinish = error => Post(() => { if (Current(id, dl)) HandleFinish(id, error); });
        _downloaders[id] = dl;
        Update(id, it =>
        {
            it.State = resumable ? DownloadState.Downloading : DownloadState.Probing;
            it.ErrorMessage = null;
            it.Speed = 0;
            if (!resumable) { it.ReceivedBytes = 0; it.Segments = []; }
        });
        dl.Start();
    }

    private bool Current(Guid id, SegmentedDownloader dl) => _downloaders.TryGetValue(id, out var d) && ReferenceEquals(d, dl);

    private void HandleProbe(Guid id, ProbeResult p) => Update(id, item =>
    {
        item.TotalBytes = p.TotalBytes;
        item.SupportsRanges = p.SupportsRanges;
        item.State = DownloadState.Downloading;
        if (!string.IsNullOrEmpty(p.SuggestedFileName))
        {
            item.FileName = Sanitize(p.SuggestedFileName);
        }
        else if (p.FinalUrl is { } final && item.FileName == Sanitize(FileNameFrom(item.Uri)) && final != item.Uri)
        {
            var candidate = FileNameFrom(final);
            if (Path.HasExtension(candidate)) item.FileName = Sanitize(candidate);
        }
        if (!Path.HasExtension(item.FileName) && ExtensionForMime(p.ContentType) is { } ext)
            item.FileName += ext;
    });

    private void HandleFinish(Guid id, Exception? error)
    {
        _downloaders.Remove(id);
        if (Find(id) is not { } item) return;
        if (error == null)
        {
            var destDir = DestinationDirectory(item);
            try
            {
                Directory.CreateDirectory(destDir);
                var dest = UniqueDestination(Path.Combine(destDir, item.FileName));
                File.SetAttributes(item.PartPath, FileAttributes.Normal);
                File.Move(item.PartPath, dest);
                MarkOfTheWeb(dest, item.Url, item.Headers.GetValueOrDefault("Referer"));
                item.FileName = Path.GetFileName(dest);
                item.FinalPath = dest;
                item.State = DownloadState.Completed;
                item.CompletedAt = DateTime.Now;
                item.Speed = 0;
                if (item.TotalBytes <= 0) item.TotalBytes = item.ReceivedBytes;
                Completed?.Invoke(item);
            }
            catch (Exception e)
            {
                item.State = DownloadState.Failed;
                item.ErrorMessage = e.Message;
            }
        }
        else if (item.State is not (DownloadState.Paused or DownloadState.Cancelled))
        {
            item.State = DownloadState.Failed;
            item.ErrorMessage = error.Message;
            item.Speed = 0;
        }
        Changed?.Invoke();
        ScheduleSave();
        PumpQueue();
    }

    // MARK: - Video (yt-dlp)

    private void StartVideo(DownloadItem item)
    {
        var id = item.Id;
        if (VideoDownloader.LocateYtDlp(_settings.YtdlpPath) is not { } exe)
        {
            Update(id, it =>
            {
                it.State = DownloadState.Failed;
                it.ErrorMessage = L.T("yt-dlp not found. Use “Install yt-dlp” in Settings.", "yt-dlp bulunamadı. Ayarlar'daki “yt-dlp'yi kur” düğmesini kullanın.");
            });
            PumpQueue();
            return;
        }
        var useCookies = !_cookielessVideos.Contains(id);
        Update(id, it =>
        {
            it.State = DownloadState.Downloading; it.ErrorMessage = null; it.ReceivedBytes = 0; it.Speed = 0; it.TotalBytes = -1;
            it.Stage = L.T("Fetching video information…", "Video bilgisi alınıyor…");
            if (useCookies) it.Log = "";   // keep the failed attempt's output visible above the retry
        });
        var outDir = DestinationDirectory(item);
        try { Directory.CreateDirectory(outDir); } catch { }
        _videoPhase[id] = (0, 0, -1);
        Process? proc = null;
        proc = VideoDownloader.Run(exe, item.Uri, outDir, _settings.YtdlpFormatArguments(), item.Headers, item.CookieFile, useCookies,
            onProgress: p => Post(() =>
            {
                if (!_videoPhase.TryGetValue(id, out var ph)) return;
                if (p.Downloaded < ph.LastDownloaded) ph.Base += ph.LastDownloaded;   // a new file started
                ph.LastDownloaded = p.Downloaded;
                _videoPhase[id] = ph;
                var received = ph.Base + p.Downloaded;
                if (Find(id) is not { } it) return;
                it.ReceivedBytes = received;
                var phaseTotal = p.Total > 0 ? ph.Base + p.Total : -1;
                it.TotalBytes = Math.Max(Math.Max(ph.ApproxTotal, phaseTotal), received);
                it.Speed = p.Speed;
            }),
            onLine: line => Post(() =>
            {
                if (Find(id) is not { } it) return;
                it.Log = (it.Log + line + "\n") is var log && log.Length > 6000 ? log[^6000..] : log;
                if (VideoDownloader.Stage(line) is { } st) it.Stage = st;
                if (line.StartsWith("MCFMT|"))
                {
                    var parts = line.Split('|');
                    if (parts.Length > 5 && double.TryParse(parts[5], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var n) && n > 0
                        && _videoPhase.TryGetValue(id, out var ph))
                    {
                        _videoPhase[id] = ph with { ApproxTotal = (long)n };
                        if (it.TotalBytes < (long)n) it.TotalBytes = (long)n;
                    }
                }
                var dest = line.IndexOf("Destination: ", StringComparison.Ordinal);
                if (dest >= 0)
                {
                    // Show the final title; strip yt-dlp's intermediate ".f137" format suffix.
                    it.FileName = VideoDownloader.FormatSuffix().Replace(Path.GetFileName(line[(dest + 13)..]), "");
                }
                if (line.StartsWith("[Merger] Merging formats into \"") && line.LastIndexOf('"') is var q2 && q2 > line.IndexOf('"'))
                {
                    var q1 = line.IndexOf('"');
                    it.FileName = Path.GetFileName(line[(q1 + 1)..q2]);
                }
            }),
            onFinish: (path, error) => Post(() =>
            {
                if (_videoProcesses.TryGetValue(id, out var current) && !ReferenceEquals(current, proc)) return;
                HandleVideoFinish(id, path, error);
            }));
        if (proc != null) _videoProcesses[id] = proc;
    }

    private void HandleVideoFinish(Guid id, string? path, Exception? error)
    {
        _videoProcesses.Remove(id);
        _videoPhase.Remove(id);
        if (Find(id) is not { } item || item.State != DownloadState.Downloading) return;   // paused/cancelled by the user
        if (error == null)
        {
            item.State = DownloadState.Completed;
            item.CompletedAt = DateTime.Now;
            item.Speed = 0;
            item.Stage = "";
            if (path != null)
            {
                item.FinalPath = path;
                item.FileName = Path.GetFileName(path);
                MarkOfTheWeb(path, item.Url, item.Headers.GetValueOrDefault("Referer"));
                try { item.TotalBytes = item.ReceivedBytes = new FileInfo(path).Length; } catch { }
            }
            else if (item.TotalBytes > 0)
            {
                item.ReceivedBytes = item.TotalBytes;
            }
            Completed?.Invoke(item);
        }
        else
        {
            if (!_cookielessVideos.Contains(id) && VideoDownloader.IsYouTube(item.Uri)
                && VideoDownloader.IsSignedInClientFailure(error.Message) && item.CookieFile != null)
            {
                _cookielessVideos.Add(id);
                item.Log += L.T("→ YouTube rejected the signed-in request; retrying without cookies…", "→ YouTube oturum açılmış isteği reddetti; çerezsiz yeniden deneniyor…") + "\n";
                StartVideo(item);
                return;
            }
            item.State = DownloadState.Failed;
            item.ErrorMessage = error.Message;
            item.Speed = 0;
        }
        Changed?.Invoke();
        ScheduleSave();
        PumpQueue();
    }

    // MARK: - User actions

    public void Pause(Guid id)
    {
        if (Find(id) is not { } item || !(item.State.IsActive() || item.State == DownloadState.Queued)) return;
        Update(id, it => { it.State = DownloadState.Paused; it.Speed = 0; });
        if (_downloaders.Remove(id, out var dl)) dl.Stop();
        if (_videoProcesses.Remove(id, out var p)) VideoDownloader.Terminate(p);
        ScheduleSave();
        PumpQueue();
    }

    public void Resume(Guid id)
    {
        if (Find(id) is not { } item || item.State is not (DownloadState.Paused or DownloadState.Failed or DownloadState.Cancelled)) return;
        Update(id, it => { it.State = DownloadState.Queued; it.ErrorMessage = null; });
        _cookielessVideos.Remove(id);
        PumpQueue();
    }

    public void Cancel(Guid id)
    {
        if (Find(id) is not { } item) return;
        if (_downloaders.Remove(id, out var dl)) dl.Stop();
        if (_videoProcesses.Remove(id, out var p)) VideoDownloader.Terminate(p);
        DeleteLater(item.PartPath);
        Update(id, it => { it.State = DownloadState.Cancelled; it.Speed = 0; it.ReceivedBytes = 0; it.Segments = []; });
        ScheduleSave();
        PumpQueue();
    }

    public void Remove(Guid id, bool deleteFile = false)
    {
        if (Find(id) is not { } item) return;
        if (_downloaders.Remove(id, out var dl)) dl.Stop();
        if (_videoProcesses.Remove(id, out var p)) VideoDownloader.Terminate(p);
        DeleteLater(item.PartPath);
        if (item.CookieFile != null) try { File.Delete(item.CookieFile); } catch { }
        if (deleteFile && item.FinalPath != null && File.Exists(item.FinalPath))
        {
            // Always to the Recycle Bin so the user can recover the file.
            try { Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(item.FinalPath, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin); } catch { }
        }
        Items.Remove(item);
        _samples.Remove(id);
        Changed?.Invoke();
        ScheduleSave();
        PumpQueue();
    }

    /// The downloader may still hold the part file open for a moment after Stop().
    private static void DeleteLater(string path) => _ = Task.Run(async () =>
    {
        for (var i = 0; i < 10 && File.Exists(path); i++)
        {
            try { File.SetAttributes(path, FileAttributes.Normal); File.Delete(path); } catch { await Task.Delay(300); }
        }
    });

    public void PauseAll() { foreach (var i in Items.Where(i => i.State.IsActive() || i.State == DownloadState.Queued).ToList()) Pause(i.Id); }
    public void ResumeAll() { foreach (var i in Items.Where(i => i.State is DownloadState.Paused or DownloadState.Failed).ToList()) Resume(i.Id); }
    public void ClearFinished() { foreach (var i in Items.Where(i => i.State is DownloadState.Completed or DownloadState.Cancelled).ToList()) Remove(i.Id); }

    public void Reveal(DownloadItem item)
    {
        if (item.FinalPath != null && File.Exists(item.FinalPath))
            Process.Start("explorer.exe", ["/select,", item.FinalPath]);
        else
        {
            var dir = DestinationDirectory(item);
            if (!Directory.Exists(dir)) dir = item.Directory;
            Directory.CreateDirectory(dir);
            Process.Start("explorer.exe", [dir]);
        }
    }

    public void Open(DownloadItem item)
    {
        if (item.FinalPath != null && File.Exists(item.FinalPath))
            Process.Start(new ProcessStartInfo(item.FinalPath) { UseShellExecute = true });
    }

    public void Shutdown()
    {
        foreach (var dl in _downloaders.Values) dl.Stop();
        foreach (var p in _videoProcesses.Values) VideoDownloader.Terminate(p);
        foreach (var i in Items.Where(i => i.State.IsActive() || i.State == DownloadState.Queued)) i.State = DownloadState.Paused;
        Save();
    }

    // MARK: - Speed

    private void Tick()
    {
        var now = DateTime.Now;
        var active = new HashSet<Guid>();
        foreach (var item in Items.Where(i => i.State == DownloadState.Downloading && i.Kind != DownloadKind.Video))
        {
            active.Add(item.Id);
            if (_samples.TryGetValue(item.Id, out var s))
            {
                var dt = (now - s.Time).TotalSeconds;
                if (dt > 0)
                {
                    var inst = Math.Max(0, (item.ReceivedBytes - s.Bytes) / dt);
                    item.Speed = item.Speed == 0 ? inst : item.Speed * 0.6 + inst * 0.4;
                }
            }
            _samples[item.Id] = (item.ReceivedBytes, now);
        }
        foreach (var k in _samples.Keys.Where(k => !active.Contains(k)).ToList()) _samples.Remove(k);
        _tickCount++;
        if (active.Count > 0 || Items.Any(i => i.State.IsActive())) Changed?.Invoke();
        if (active.Count > 0 && _tickCount % 10 == 0) Save();   // segment state to disk every 5 s
    }

    // MARK: - Persistence

    private void Load()
    {
        try
        {
            if (!File.Exists(StorePath)) return;
            Items = JsonSerializer.Deserialize<List<DownloadItem>>(File.ReadAllText(StorePath), JsonOptions) ?? [];
            foreach (var i in Items)
            {
                if (i.State.IsActive() || i.State == DownloadState.Queued) i.State = DownloadState.Paused;
                i.Speed = 0;
            }
        }
        catch { Items = []; }
        CleanupOrphanParts();
    }

    /// Deletes `.dm-<id>.part` files left by downloads that are no longer in the list.
    private void CleanupOrphanParts()
    {
        try
        {
            var dir = _settings.DownloadDirectory;
            if (!Directory.Exists(dir)) return;
            var known = Items.Select(i => $".dm-{i.Id}.part").ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var f in Directory.EnumerateFiles(dir, ".dm-*.part"))
                if (!known.Contains(Path.GetFileName(f))) try { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); } catch { }
        }
        catch { }
    }

    public void Save()
    {
        try
        {
            var tmp = StorePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Items, JsonOptions));
            File.Move(tmp, StorePath, overwrite: true);
        }
        catch { }
    }

    private void ScheduleSave()
    {
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private static string? WriteCookieFile(List<BrowserCookie> cookies, Guid id)
    {
        var sb = new StringBuilder("# Netscape HTTP Cookie File\n");
        foreach (var c in cookies)
        {
            if (c.Name.Contains('\t') || c.Value.Contains('\n') || c.Domain.Contains('\t')) continue;
            var flag = c.Domain.StartsWith('.') ? "TRUE" : "FALSE";
            sb.Append(string.Join('\t', c.Domain, flag, c.Path, c.Secure ? "TRUE" : "FALSE", c.ExpirationDate.ToString(), c.Name, c.Value)).Append('\n');
        }
        try
        {
            // %APPDATA% is only readable by the user, so the cookie file needs no extra ACL.
            var dir = Path.Combine(AppSettings.SupportDirectory, "cookies");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, $"{id}.txt");
            File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
            return path;
        }
        catch { return null; }
    }

    // MARK: - File name helpers

    public static string FileNameFrom(Uri url)
    {
        var last = url.Segments.Length > 0 ? url.Segments[^1].Trim('/') : "";
        var name = Uri.UnescapeDataString(last);
        return string.IsNullOrEmpty(name) ? (url.Host.Length > 0 ? url.Host : "download") : name;
    }

    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// Makes a server- or page-supplied name safe as a single Windows file name (no folders, no device names).
    public static string Sanitize(string s)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s) sb.Append(invalid.Contains(ch) || char.IsControl(ch) ? '_' : ch);
        var n = sb.ToString().Trim().TrimEnd('.', ' ');
        if (n.StartsWith('.')) n = "_" + n;
        if (Reserved.Contains(Path.GetFileNameWithoutExtension(n))) n = "_" + n;
        if (n.Length > 200)
        {
            var ext = Path.GetExtension(n);
            if (ext.Length > 16) ext = "";
            n = Path.GetFileNameWithoutExtension(n)[..Math.Min(180, Path.GetFileNameWithoutExtension(n).Length)] + ext;
        }
        return n.Length == 0 ? "download" : n;
    }

    public static string UniqueDestination(string path)
    {
        if (!File.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path)!;
        var ext = Path.GetExtension(path);
        var b = Path.GetFileNameWithoutExtension(path);
        for (var n = 2; ; n++)
        {
            var candidate = Path.Combine(dir, $"{b} ({n}){ext}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    private static string? ExtensionForMime(string? contentType)
    {
        if (string.IsNullOrEmpty(contentType)) return null;
        try
        {
            using var key = Registry.ClassesRoot.OpenSubKey($@"MIME\Database\Content Type\{contentType}");
            var ext = key?.GetValue("Extension") as string;
            return string.IsNullOrEmpty(ext) || ext.Equals(".bin", StringComparison.OrdinalIgnoreCase) ? null : ext;
        }
        catch { return null; }
    }

    /// Windows' counterpart of macOS quarantine: SmartScreen and Office treat the file as downloaded from the internet.
    public static void MarkOfTheWeb(string path, string url, string? referrer)
    {
        try
        {
            var sb = new StringBuilder("[ZoneTransfer]\r\nZoneId=3\r\n");
            if (!string.IsNullOrEmpty(referrer) && referrer.StartsWith("http")) sb.Append($"ReferrerUrl={referrer}\r\n");
            sb.Append($"HostUrl={url}\r\n");
            File.WriteAllText(path + ":Zone.Identifier", sb.ToString());
        }
        catch { }
    }
}
