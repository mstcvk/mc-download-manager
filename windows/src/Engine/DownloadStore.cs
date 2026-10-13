using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Windows.Threading;
using Microsoft.Win32;

namespace MCDM;

public sealed record BrowserCookie(string Name, string Value, string Domain, string Path, bool Secure, double ExpirationDate);

public sealed class NewDownloadRequest(Uri url)
{
    public Uri Url { get; } = url;
    public string? FileName { get; set; }
    public string? Referer { get; set; }
    public string? UserAgent { get; set; }
    public string? CookieHeader { get; set; }
    public List<BrowserCookie>? Cookies { get; set; }
    public DownloadKind Kind { get; set; } = DownloadKind.File;
    public Dictionary<string, string> ExtraHeaders { get; set; } = [];
    public int? Segments { get; set; }
}

/// State of all downloads, the queue and persistence. Used on the UI thread only.
public sealed class DownloadStore : INotifyPropertyChanged
{
    public ObservableCollection<DownloadItem> Items { get; } = [];
    public AppSettings Settings { get; }

    readonly Dictionary<Guid, SegmentedDownloader> downloaders = [];
    readonly Dictionary<Guid, Process> videoProcesses = [];
    /// yt-dlp downloads several files (video, audio): bytes completed in earlier phases + approx total.
    readonly Dictionary<Guid, (long Base, long Last, long Approx)> videoPhase = [];
    /// YouTube downloads waiting for the deno install prompt / install to finish.
    readonly List<Guid> denoWaiters = [];
    bool denoPrompting, denoDeclinedThisLaunch;
    /// Video downloads that are retried without cookies after YouTube rejected the signed-in client.
    readonly HashSet<Guid> cookielessVideos = [];
    readonly Dictionary<Guid, (long Bytes, DateTime Time)> samples = [];
    readonly DispatcherTimer timer, saveTimer;
    int tickCount;
    readonly string storePath = Path.Combine(AppSettings.SupportDir, "downloads.json");

    public event PropertyChangedEventHandler? PropertyChanged;

    public DownloadStore(AppSettings settings)
    {
        Settings = settings;
        Directory.CreateDirectory(AppSettings.SupportDir);
        Load();
        saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        saveTimer.Tick += (_, _) => { saveTimer.Stop(); Save(); };
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    // MARK: - Queries

    /// Final folder for an item: base folder, plus a category subfolder when enabled.
    public string DestinationDirectory(DownloadItem item) =>
        Settings.OrganizeByCategory ? Path.Combine(item.Directory, item.Category.Label()) : item.Directory;

    public string DestinationPath(DownloadItem item) => Path.Combine(DestinationDirectory(item), item.FileName);

    public int ActiveCount => Items.Count(i => i.State.IsActive());
    public int UnfinishedCount => Items.Count(i => !i.IsFinished);
    public double TotalSpeed => Items.Where(i => i.State == DownloadState.Downloading).Sum(i => i.Speed);

    /// Byte-weighted progress of active downloads with a known size (null when nothing measurable is running).
    public double? OverallProgress
    {
        get
        {
            var m = Items.Where(i => i.State.IsActive() && i.TotalBytes > 0).ToList();
            if (m.Count == 0) return null;
            long total = m.Sum(i => i.TotalBytes), got = m.Sum(i => Math.Min(i.ReceivedBytes, i.TotalBytes));
            return total > 0 ? (double)got / total : null;
        }
    }

    public void PrepareDownloadFolder()
    {
        try { Directory.CreateDirectory(Settings.DownloadDirectory); } catch { }
    }

    DownloadItem? Find(Guid id) => Items.FirstOrDefault(i => i.Id == id);

    void Update(Guid id, Action<DownloadItem> mutate)
    {
        if (Find(id) is not { } item) return;
        mutate(item);
        item.Changed();
    }

    // MARK: - Adding

    public DownloadItem Add(NewDownloadRequest req)
    {
        var headers = new Dictionary<string, string>(req.ExtraHeaders, StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(req.Referer)) headers["Referer"] = req.Referer;
        if (!string.IsNullOrEmpty(req.UserAgent)) headers["User-Agent"] = req.UserAgent;
        if (!string.IsNullOrEmpty(req.CookieHeader)) headers["Cookie"] = req.CookieHeader;
        if (!headers.ContainsKey("User-Agent")) headers["User-Agent"] = DefaultUserAgent;

        var name = string.IsNullOrEmpty(req.FileName) ? FileNameFrom(req.Url) : req.FileName;
        if (req.Kind == DownloadKind.Video) name = req.Url.Host.Length > 0 ? req.Url.Host : "video";

        var item = new DownloadItem
        {
            Url = req.Url,
            FileName = Sanitize(name),
            Directory = Settings.DownloadDirectory,
            Kind = req.Kind,
            Headers = new Dictionary<string, string>(headers),
            RequestedSegments = req.Segments ?? 0,
        };
        if (req.Kind == DownloadKind.Video && req.Cookies is { Count: > 0 } cookies) item.CookieFile = WriteCookieFile(cookies, item.Id);
        try { Directory.CreateDirectory(item.Directory); } catch { }
        Items.Insert(0, item);
        ScheduleSave();
        if (Settings.AutoStart) PumpQueue();
        if (Settings.ShowDetailOnStart) DetailWindows.Show(item.Id, this);
        return item;
    }

    public void AddUrls(string text, DownloadKind kind, int? segments = null)
    {
        foreach (var line in text.Split('\n', '\r'))
        {
            var s = line.Trim();
            if (!Uri.TryCreate(s, UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https")) continue;
            Add(new NewDownloadRequest(url) { Kind = kind, Segments = segments });
        }
    }

    // MARK: - Queue

    public void PumpQueue()
    {
        int slots = Math.Max(0, Settings.MaxConcurrent - ActiveCount);
        foreach (var item in Items.Reverse().ToList())
        {
            if (slots <= 0) break;
            if (item.State != DownloadState.Queued) continue;
            StartItem(item);
            slots--;
        }
    }

    void StartItem(DownloadItem item)
    {
        if (item.Kind == DownloadKind.Video) StartVideo(item); else StartFile(item);
    }

    static void OnUi(Action a) => System.Windows.Application.Current?.Dispatcher.BeginInvoke(a);

    void StartFile(DownloadItem item)
    {
        bool resumable = item.SupportsRanges && item.TotalBytes > 0 && item.Segments.Count > 0 && File.Exists(item.PartPath);
        var cfg = new SegmentedDownloader.Configuration
        {
            Url = item.Url,
            Headers = item.Headers,
            PartPath = item.PartPath,
            SegmentCount = item.RequestedSegments > 0 ? item.RequestedSegments : Settings.SegmentCount,
        };
        if (resumable)
        {
            cfg.ResumeSegments = item.Segments;
            cfg.ResumeTotal = item.TotalBytes;
        }
        var dl = new SegmentedDownloader(cfg);
        var id = item.Id;
        dl.OnProbe = p => OnUi(() => { if (downloaders.GetValueOrDefault(id) == dl) HandleProbe(id, p); });
        dl.OnProgress = (received, segs) => OnUi(() =>
        {
            if (downloaders.GetValueOrDefault(id) != dl) return;
            Update(id, i =>
            {
                i.ReceivedBytes = received;
                i.Segments = segs;
                if (i.State == DownloadState.Probing) i.State = DownloadState.Downloading;
            });
        });
        dl.OnFinish = error => OnUi(() => { if (downloaders.GetValueOrDefault(id) == dl) HandleFinish(id, error); });
        downloaders[id] = dl;
        Update(id, i =>
        {
            i.State = resumable ? DownloadState.Downloading : DownloadState.Probing;
            i.ErrorMessage = null;
            i.Speed = 0;
            if (!resumable) { i.ReceivedBytes = 0; i.Segments = []; }
        });
        dl.Start();
    }

    void HandleProbe(Guid id, ProbeResult p) => Update(id, item =>
    {
        // A probe answer can arrive after the user paused; resuming probes again.
        if (item.State is not (DownloadState.Probing or DownloadState.Downloading)) return;
        item.TotalBytes = p.TotalBytes;
        item.SupportsRanges = p.SupportsRanges;
        item.State = DownloadState.Downloading;
        if (!string.IsNullOrEmpty(p.SuggestedFileName))
        {
            item.FileName = Sanitize(p.SuggestedFileName);
        }
        else if (p.FinalUrl is { } final && item.FileName == Sanitize(FileNameFrom(item.Url)) && final != item.Url)
        {
            var candidate = FileNameFrom(final);
            if (Path.GetExtension(candidate).Length > 0) item.FileName = Sanitize(candidate);
        }
        if (Path.GetExtension(item.FileName).Length == 0 && p.ContentType is { } ct && ExtensionForMime(ct) is { } ext && ext != "bin")
            item.FileName += "." + ext;
    });

    void HandleFinish(Guid id, Exception? error)
    {
        downloaders.Remove(id);
        if (Find(id) is { } item)
        {
            if (error == null)
            {
                var destDir = DestinationDirectory(item);
                try
                {
                    Directory.CreateDirectory(destDir);
                    var dest = UniqueDestination(Path.Combine(destDir, item.FileName));
                    File.Move(item.PartPath, dest);
                    File.SetAttributes(dest, File.GetAttributes(dest) & ~FileAttributes.Hidden);
                    MarkOfTheWeb(dest, item.Url, item.Headers.GetValueOrDefault("Referer"));
                    item.FileName = Path.GetFileName(dest);
                    item.FinalPath = dest;
                    item.State = DownloadState.Completed;
                    item.CompletedAt = DateTime.Now;
                    item.Speed = 0;
                    if (item.TotalBytes <= 0) item.TotalBytes = item.ReceivedBytes;
                    item.Changed();
                    NotifyCompleted(item);
                    DetailWindows.DidComplete(id, Settings.AutoCloseDetail);
                }
                catch (Exception e)
                {
                    item.State = DownloadState.Failed;
                    item.ErrorMessage = e.Message;
                    item.Changed();
                }
            }
            else if (item.State is not (DownloadState.Paused or DownloadState.Cancelled))
            {
                item.State = DownloadState.Failed;
                item.ErrorMessage = error.Message;
                item.Speed = 0;
                item.Changed();
            }
        }
        ScheduleSave();
        PumpQueue();
    }

    // MARK: - Video (yt-dlp)

    void StartVideo(DownloadItem item)
    {
        var id = item.Id;
        if (VideoDownloader.LocateYtDlp(Settings.YtdlpPath) is not { } exe)
        {
            Update(id, i =>
            {
                i.State = DownloadState.Failed;
                i.ErrorMessage = L.T("yt-dlp not found. Use “Install yt-dlp” in Settings ▸ Video.");
            });
            PumpQueue();
            return;
        }
        if (VideoDownloader.IsYouTube(item.Url) && VideoDownloader.LocateDeno() == null
            && !Settings.DenoPromptSuppressed && !denoDeclinedThisLaunch)
        {
            Update(id, i =>
            {
                i.State = DownloadState.Downloading; i.ErrorMessage = null; i.Speed = 0;
                i.Stage = L.T("Waiting for the JavaScript runtime (deno)…");
            });
            if (!denoWaiters.Contains(id)) denoWaiters.Add(id);
            if (!denoPrompting)
            {
                denoPrompting = true;
                OnUi(PromptForDeno);
            }
            return;
        }
        bool useCookies = !cookielessVideos.Contains(id);
        Update(id, i =>
        {
            i.State = DownloadState.Downloading; i.ErrorMessage = null; i.ReceivedBytes = 0; i.Speed = 0; i.TotalBytes = -1;
            i.Stage = L.T("Fetching video information…");
            if (useCookies) i.Log = "";   // keep the failed attempt's output visible above the retry
        });
        var outDir = DestinationDirectory(item);
        try { Directory.CreateDirectory(outDir); } catch { }
        videoPhase[id] = (0, 0, -1);
        var proc = VideoDownloader.Run(exe, item.Url, outDir, Settings.YtdlpFormatArguments, item.Headers, item.CookieFile, useCookies,
            onProgress: p => OnUi(() =>
            {
                var ph = videoPhase.GetValueOrDefault(id, (0, 0, -1));
                if (p.Downloaded < ph.Last) ph.Base += ph.Last;   // new file started
                ph.Last = p.Downloaded;
                videoPhase[id] = ph;
                long received = ph.Base + p.Downloaded;
                Update(id, i =>
                {
                    i.ReceivedBytes = received;
                    long phaseTotal = p.Total > 0 ? ph.Base + p.Total : -1;
                    i.TotalBytes = Math.Max(Math.Max(ph.Approx, phaseTotal), received);
                    i.Speed = p.Speed;
                });
            }),
            onLine: line => OnUi(() => Update(id, i =>
            {
                var log = i.Log + line + "\n";
                i.Log = log.Length > 6000 ? log[^6000..] : log;
                if (VideoDownloader.Stage(line) is { } st) i.Stage = st;
                if (line.StartsWith("MCFMT|"))
                {
                    var parts = line.Split('|');
                    if (parts.Length > 5 && double.TryParse(parts[5], System.Globalization.CultureInfo.InvariantCulture, out var n) && n > 0)
                    {
                        var ph = videoPhase.GetValueOrDefault(id, (0, 0, -1));
                        ph.Approx = (long)n;
                        videoPhase[id] = ph;
                        if (i.TotalBytes < (long)n) i.TotalBytes = (long)n;
                    }
                }
                var dest = line.IndexOf("Destination: ", StringComparison.Ordinal);
                if (dest >= 0)
                {
                    // Show the final title; strip yt-dlp's intermediate ".f137" format suffix.
                    i.FileName = VideoDownloader.FormatSuffix().Replace(Path.GetFileName(line[(dest + 13)..]), "");
                }
                if (line.StartsWith("[Merger] Merging formats into \""))
                {
                    int q1 = line.IndexOf('"'), q2 = line.LastIndexOf('"');
                    if (q1 < q2) i.FileName = Path.GetFileName(line[(q1 + 1)..q2]);
                }
            })),
            onFinish: (path, error) => OnUi(() => HandleVideoFinish(id, path, error)));
        if (proc != null) videoProcesses[id] = proc;
    }

    void HandleVideoFinish(Guid id, string? path, Exception? error)
    {
        videoProcesses.Remove(id);
        videoPhase.Remove(id);
        if (Find(id) is not { } item || item.State != DownloadState.Downloading) return;   // paused / cancelled by the user
        if (error == null)
        {
            item.State = DownloadState.Completed;
            item.CompletedAt = DateTime.Now;
            item.Speed = 0;
            if (path != null)
            {
                item.FinalPath = path;
                item.FileName = Path.GetFileName(path);
                MarkOfTheWeb(path, item.Url, null);
                try { item.TotalBytes = item.ReceivedBytes = new FileInfo(path).Length; } catch { }
            }
            else if (item.TotalBytes > 0)
            {
                item.ReceivedBytes = item.TotalBytes;
            }
            item.Changed();
            NotifyCompleted(item);
            DetailWindows.DidComplete(id, Settings.AutoCloseDetail);
        }
        else
        {
            if (!cookielessVideos.Contains(id) && VideoDownloader.IsYouTube(item.Url)
                && VideoDownloader.IsSignedInClientFailure(error.Message)
                && VideoDownloader.HasCookies(item.CookieFile, item.Url.Host))
            {
                cookielessVideos.Add(id);
                item.Log += L.T("→ YouTube rejected the signed-in request; retrying without cookies…") + "\n";
                item.Changed();
                StartVideo(item);
                return;
            }
            item.State = DownloadState.Failed;
            item.ErrorMessage = error.Message;
            item.Speed = 0;
            item.Changed();
        }
        ScheduleSave();
        PumpQueue();
    }

    /// Asks once whether to install deno, which yt-dlp needs for YouTube, then starts the waiting downloads.
    void PromptForDeno()
    {
        var (button, suppress) = Dialogs.Ask(
            L.T("Install the JavaScript runtime for YouTube?"),
            L.T("YouTube now requires yt-dlp to run JavaScript (deno) to unlock video streams. Without it, YouTube downloads may fail with errors such as “The page needs to be reloaded” or “n challenge solving failed”.\n\nMC Download Manager can download deno (%@) from its official GitHub releases and keep it in its own AppData folder.", ToolInstaller.DenoDownloadSize),
            [L.T("Install deno"), L.T("Not Now")],
            L.T("Don’t ask again"));
        if (suppress) Settings.DenoPromptSuppressed = true;
        if (button != 0)
        {
            denoDeclinedThisLaunch = true;
            ResumeDenoWaiters();
            return;
        }
        foreach (var id in denoWaiters) Update(id, i => i.Stage = L.T("Installing deno…"));
        ToolInstaller.Shared.InstallDeno(error =>
        {
            if (error != null)
            {
                denoDeclinedThisLaunch = true;   // don't loop on a failing install; Settings ▸ Video can retry
                foreach (var id in denoWaiters) Update(id, i => i.Log += L.T("deno could not be installed: %@", error.Message) + "\n");
            }
            ResumeDenoWaiters();
        });
    }

    void ResumeDenoWaiters()
    {
        denoPrompting = false;
        var waiting = denoWaiters.ToList();
        denoWaiters.Clear();
        foreach (var id in waiting)
            if (Find(id) is { State: DownloadState.Downloading } item) StartVideo(item);
    }

    // MARK: - User actions

    public void Pause(Guid id)
    {
        if (Find(id) is not { } item || !(item.State.IsActive() || item.State == DownloadState.Queued)) return;
        Update(id, i => { i.State = DownloadState.Paused; i.Speed = 0; });
        if (downloaders.GetValueOrDefault(id) is { } dl) dl.Stop();
        if (videoProcesses.Remove(id, out var p)) Kill(p);
        ScheduleSave();
        PumpQueue();
    }

    public void Resume(Guid id)
    {
        if (Find(id) is not { State: DownloadState.Paused or DownloadState.Failed or DownloadState.Cancelled }) return;
        Update(id, i => { i.State = DownloadState.Queued; i.ErrorMessage = null; });
        cookielessVideos.Remove(id);
        PumpQueue();
    }

    public void Cancel(Guid id)
    {
        if (Find(id) is not { } item) return;
        if (downloaders.Remove(id, out var dl)) dl.Stop();
        if (videoProcesses.Remove(id, out var p)) Kill(p);
        TryDelete(item.PartPath);
        Update(id, i => { i.State = DownloadState.Cancelled; i.Speed = 0; i.ReceivedBytes = 0; i.Segments = []; });
        ScheduleSave();
        PumpQueue();
    }

    public void Remove(Guid id, bool deleteFile = false)
    {
        if (Find(id) is not { } item) return;
        if (downloaders.Remove(id, out var dl)) dl.Stop();
        if (videoProcesses.Remove(id, out var p)) Kill(p);
        TryDelete(item.PartPath);
        if (item.CookieFile != null) TryDelete(item.CookieFile);
        if (deleteFile && item.FinalPath != null && File.Exists(item.FinalPath))
        {
            // Always move to the Recycle Bin so the user can recover the file.
            try
            {
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(item.FinalPath,
                    Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            }
            catch { }
        }
        Items.Remove(item);
        samples.Remove(id);
        ScheduleSave();
        PumpQueue();
    }

    public void PauseAll() { foreach (var i in Items.Where(i => i.State.IsActive() || i.State == DownloadState.Queued).ToList()) Pause(i.Id); }
    public void ResumeAll() { foreach (var i in Items.Where(i => i.State is DownloadState.Paused or DownloadState.Failed).ToList()) Resume(i.Id); }
    public void ClearFinished() { foreach (var i in Items.Where(i => i.State is DownloadState.Completed or DownloadState.Cancelled).ToList()) Remove(i.Id); }

    public void RevealInExplorer(DownloadItem item)
    {
        if (item.FinalPath != null && File.Exists(item.FinalPath))
            Process.Start("explorer.exe", $"/select,\"{item.FinalPath}\"");
        else
            Shell.Open(DestinationDirectory(item));
    }

    public void Open(DownloadItem item)
    {
        if (item.FinalPath != null) Shell.Open(item.FinalPath);
    }

    public void Shutdown()
    {
        PauseAll();
        Save();
    }

    static void Kill(Process p)
    {
        try { p.Kill(entireProcessTree: true); } catch { }   // yt-dlp runs ffmpeg as a child
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    // MARK: - Speed

    void Tick()
    {
        var now = DateTime.UtcNow;
        var active = new HashSet<Guid>();
        foreach (var item in Items)
        {
            if (item.State != DownloadState.Downloading || item.Kind == DownloadKind.Video) continue;
            active.Add(item.Id);
            if (samples.TryGetValue(item.Id, out var s))
            {
                var dt = (now - s.Time).TotalSeconds;
                if (dt > 0)
                {
                    var inst = Math.Max(0, (item.ReceivedBytes - s.Bytes) / dt);
                    item.Speed = item.Speed == 0 ? inst : item.Speed * 0.6 + inst * 0.4;
                    item.Changed();
                }
            }
            samples[item.Id] = (item.ReceivedBytes, now);
        }
        foreach (var id in samples.Keys.Where(k => !active.Contains(k)).ToList()) samples.Remove(id);
        DetailWindows.RefreshTitles(Items);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        tickCount++;
        if (active.Count > 0 && tickCount % 10 == 0) Save();   // segment state to disk every 5 s
    }

    // MARK: - Persistence

    void Load()
    {
        try
        {
            var arr = JsonSerializer.Deserialize<List<DownloadItem>>(File.ReadAllText(storePath)) ?? [];
            foreach (var i in arr)
            {
                if (i.State.IsActive() || i.State == DownloadState.Queued) i.State = DownloadState.Paused;
                Items.Add(i);
            }
        }
        catch { }
        CleanupOrphanParts();
    }

    /// Deletes `.dm-<id>.part` files left over from downloads that are no longer in the list.
    void CleanupOrphanParts()
    {
        try
        {
            var known = Items.Select(i => $".dm-{i.Id}.part").ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var f in Directory.EnumerateFiles(Settings.DownloadDirectory, ".dm-*.part"))
                if (!known.Contains(Path.GetFileName(f))) TryDelete(f);
        }
        catch { }
    }

    void Save()
    {
        try
        {
            var tmp = storePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Items));
            File.Move(tmp, storePath, true);
        }
        catch { }
    }

    void ScheduleSave()
    {
        saveTimer.Stop();
        saveTimer.Start();
    }

    string? WriteCookieFile(List<BrowserCookie> cookies, Guid id)
    {
        var lines = new List<string> { "# Netscape HTTP Cookie File" };
        foreach (var c in cookies)
        {
            if (string.IsNullOrEmpty(c.Name) || string.IsNullOrEmpty(c.Domain)) continue;
            var flag = c.Domain.StartsWith('.') ? "TRUE" : "FALSE";
            lines.Add(string.Join('\t', c.Domain, flag, string.IsNullOrEmpty(c.Path) ? "/" : c.Path, c.Secure ? "TRUE" : "FALSE",
                ((long)c.ExpirationDate).ToString(), c.Name, c.Value));
        }
        var dir = Path.Combine(AppSettings.SupportDir, "cookies");
        try
        {
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, $"{id}.txt");
            File.WriteAllText(path, string.Join("\n", lines) + "\n");
            return path;
        }
        catch { return null; }
    }

    // MARK: - Notification

    void NotifyCompleted(DownloadItem item)
    {
        if (Settings.NotifyOnComplete) TrayIcon.Notify(L.T("Download completed"), item.FileName, item.Id);
    }

    public const string DefaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

    /// Tags a downloaded file like a browser download would (Mark of the Web), so SmartScreen and
    /// Office Protected View assess it on first open.
    public static void MarkOfTheWeb(string file, Uri source, string? referer)
    {
        try
        {
            var text = "[ZoneTransfer]\r\nZoneId=3\r\n" + (string.IsNullOrEmpty(referer) ? "" : $"ReferrerUrl={referer}\r\n") + $"HostUrl={source.AbsoluteUri}\r\n";
            File.WriteAllText(file + ":Zone.Identifier", text);
        }
        catch { }
    }

    // MARK: - File name helpers

    public static string FileNameFrom(Uri url)
    {
        var last = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        try { last = Uri.UnescapeDataString(last); } catch { }
        return last.Length > 0 ? last : url.Host.Length > 0 ? url.Host : "download";
    }

    static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    public static string Sanitize(string s)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var n = new string(s.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim().TrimEnd('.', ' ');
        if (n.StartsWith('.')) n = "_" + n;
        if (n.Length > 200)
        {
            var ext = Path.GetExtension(n);
            var stem = Path.GetFileNameWithoutExtension(n);
            n = stem[..Math.Min(stem.Length, 180)] + (ext.Length <= 16 ? ext : "");
        }
        if (ReservedNames.Contains(Path.GetFileNameWithoutExtension(n))) n = "_" + n;
        return n.Length == 0 ? "download" : n;
    }

    public static string UniqueDestination(string path)
    {
        if (!File.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path)!;
        var ext = Path.GetExtension(path);
        var stem = Path.GetFileNameWithoutExtension(path);
        for (int n = 2; ; n++)
        {
            var candidate = Path.Combine(dir, $"{stem} ({n}){ext}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    /// File extension (no dot) Windows associates with a MIME type.
    static string? ExtensionForMime(string mime)
    {
        try
        {
            using var key = Registry.ClassesRoot.OpenSubKey($@"MIME\Database\Content Type\{mime}");
            return (key?.GetValue("Extension") as string)?.TrimStart('.');
        }
        catch { return null; }
    }
}

public static class Shell
{
    public static void Open(string pathOrUrl)
    {
        try { Process.Start(new ProcessStartInfo(pathOrUrl) { UseShellExecute = true }); } catch { }
    }
}
