using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace MCDownloadManager;

/// yt-dlp wrapper. Prefers the copy installed by the app, then one next to the exe, then PATH (winget, scoop…).
public static partial class VideoDownloader
{
    public static string ToolsDirectory => Path.Combine(AppSettings.LocalDirectory, "bin");

    public static string? LocateYtDlp(string custom) => Locate("yt-dlp.exe", custom);
    public static string? LocateFfmpeg() => Locate("ffmpeg.exe");
    /// deno is the JavaScript runtime yt-dlp uses to solve YouTube's n/signature challenges.
    public static string? LocateDeno() => Locate("deno.exe");

    private static string? Locate(string exe, string custom = "")
    {
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(custom)) candidates.Add(custom.Trim().Trim('"'));
        candidates.Add(Path.Combine(ToolsDirectory, exe));
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "tools", exe));
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(Path.Combine(dir.Trim().Trim('"'), exe));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Links", exe));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop", "shims", exe));
        foreach (var c in candidates)
        {
            try { if (File.Exists(c)) return Path.GetFullPath(c); } catch { }
        }
        return null;
    }

    public static bool IsYouTube(Uri url)
    {
        var h = url.Host.ToLowerInvariant();
        return h == "youtu.be" || h == "youtube.com" || h.EndsWith(".youtube.com") || h == "youtube-nocookie.com" || h.EndsWith(".youtube-nocookie.com");
    }

    /// YouTube rejects the signed-in clients yt-dlp picks when cookies are passed
    /// ("The page needs to be reloaded"); the same video usually works without cookies.
    public static bool IsSignedInClientFailure(string message) =>
        message.Contains("page needs to be reloaded", StringComparison.OrdinalIgnoreCase);

    public readonly record struct Progress(long Downloaded, long Total, double Speed);

    [GeneratedRegex(@"\.f[0-9]+[-a-z0-9]*\.(m4a|webm|opus|mp3|aac|ogg)$")]
    private static partial Regex AudioPart();
    [GeneratedRegex(@"\.f[0-9]+[-a-z0-9]*\.[a-z0-9]+$")]
    private static partial Regex FormatPart();
    [GeneratedRegex(@"\.f[0-9]+[-a-z0-9]*(?=\.[a-z0-9]+$)")]
    public static partial Regex FormatSuffix();

    /// Turns a yt-dlp log line into a user-facing phase description, if it marks a new phase.
    public static string? Stage(string line)
    {
        if (line.StartsWith("[download] Destination:"))
        {
            var lower = line["[download] Destination: ".Length..].ToLowerInvariant();
            // yt-dlp names intermediate files <title>.f<formatid>.<ext>
            if (AudioPart().IsMatch(lower)) return L.T("Downloading audio…", "Ses indiriliyor…");
            if (FormatPart().IsMatch(lower)) return L.T("Downloading video…", "Video indiriliyor…");
            return L.T("Downloading…", "İndiriliyor…");
        }
        if (line.StartsWith("[Merger]")) return L.T("Merging video and audio (ffmpeg)…", "Video ve ses birleştiriliyor (ffmpeg)…");
        if (line.StartsWith("[VideoRemuxer]") || line.StartsWith("[VideoConvertor]")) return L.T("Converting container (ffmpeg)…", "Kapsayıcı dönüştürülüyor (ffmpeg)…");
        if (line.StartsWith("[ExtractAudio]")) return L.T("Extracting audio (ffmpeg)…", "Ses ayıklanıyor (ffmpeg)…");
        if (line.StartsWith("MCFMT|"))
        {
            var p = line.Split('|');
            if (p.Length < 6) return null;
            var parts = new List<string>();
            if (p[1] != "NA" && p[1].Length > 0) parts.Add(p[1]);
            if (p[2] != "NA") parts.Add(p[2].ToUpperInvariant());
            if (p[3] != "NA" && p[3] != "none") parts.Add(p[3].Split('.')[0]);
            if (double.TryParse(p[5], NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && n > 0) parts.Add("~" + Fmt.Size((long)n));
            return L.T("Selected: ", "Seçilen: ") + string.Join(" · ", parts);
        }
        if (line.Contains("has already been downloaded")) return L.T("File already downloaded", "Dosya zaten indirilmiş");
        return null;
    }

    public static string? MergedCookieFile(string? itemCookies) =>
        itemCookies != null && File.Exists(itemCookies) ? itemCookies : null;

    /// Starts yt-dlp. Callbacks run on background threads; onFinish gets the final file path (or null) or an error.
    public static Process? Run(string executable, Uri url, string outputDir, List<string> formatArgs,
        Dictionary<string, string> headers, string? cookieFile, bool useCookies,
        Action<Progress> onProgress, Action<string> onLine, Action<string?, Exception?> onFinish)
    {
        var psi = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = outputDir,
        };
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        psi.Environment["PYTHONUTF8"] = "1";
        // Arguments go through ArgumentList (no shell), so nothing in the URL or headers can inject options.
        string[] args =
        [
            "--newline", "--no-playlist", "--no-colors", "--progress", "--no-simulate", "--no-mtime", "--no-quiet",
            "--encoding", "utf-8", "--windows-filenames",
            "-N", "4",
            "-o", Path.Combine(outputDir, "%(title).150B [%(id)s].%(ext)s"),
            "--progress-template",
            "download:DMP|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s",
            "--print", "after_move:filepath",
            "--print", "before_dl:MCFMT|%(resolution)s|%(ext)s|%(vcodec)s|%(acodec)s|%(filesize_approx)s|%(format_id)s|%(duration)s",
        ];
        foreach (var a in args) psi.ArgumentList.Add(a);
        foreach (var a in formatArgs) psi.ArgumentList.Add(a);
        if (LocateFfmpeg() is { } ff) { psi.ArgumentList.Add("--ffmpeg-location"); psi.ArgumentList.Add(ff); }
        if (headers.TryGetValue("User-Agent", out var ua) && ua.Length > 0) { psi.ArgumentList.Add("--user-agent"); psi.ArgumentList.Add(ua); }
        if (headers.TryGetValue("Referer", out var rf) && rf.Length > 0) { psi.ArgumentList.Add("--referer"); psi.ArgumentList.Add(rf); }
        if (useCookies && MergedCookieFile(cookieFile) is { } cf) { psi.ArgumentList.Add("--cookies"); psi.ArgumentList.Add(cf); }
        if (LocateDeno() is { } deno) { psi.ArgumentList.Add("--js-runtimes"); psi.ArgumentList.Add("deno:" + deno); }
        psi.ArgumentList.Add("--");
        psi.ArgumentList.Add(url.AbsoluteUri);

        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        var gate = new object();
        string? finalPath = null;
        string? lastError = null;

        void Handle(string? raw, bool isError)
        {
            var line = raw?.Trim();
            if (string.IsNullOrEmpty(line)) return;
            if (line.StartsWith("DMP|"))
            {
                var parts = line.Split('|');
                if (parts.Length < 5) return;
                static long Num(string s) => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? (long)d : -1;
                var total = Num(parts[2]);
                if (total <= 0) total = Num(parts[3]);
                _ = double.TryParse(parts[4], NumberStyles.Float, CultureInfo.InvariantCulture, out var speed);
                onProgress(new Progress(Math.Max(0, Num(parts[1])), total, Math.Max(0, speed)));
                return;
            }
            try
            {
                if (Path.IsPathFullyQualified(line) && File.Exists(line)) lock (gate) finalPath = line;
            }
            catch { }
            if (isError && line.StartsWith("ERROR")) lock (gate) lastError = line;
            onLine(line);
        }

        p.OutputDataReceived += (_, e) => Handle(e.Data, false);
        p.ErrorDataReceived += (_, e) => Handle(e.Data, true);
        try
        {
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }
        catch (Exception e)
        {
            onFinish(null, e);
            return null;
        }
        _ = Task.Run(async () =>
        {
            await p.WaitForExitAsync();   // also waits until the redirected output is drained
            string? path, err;
            lock (gate) { path = finalPath; err = lastError; }
            if (p.ExitCode == 0) onFinish(path, null);
            else onFinish(null, new DownloadFailure(err ?? L.T($"yt-dlp exited with code {p.ExitCode}", $"yt-dlp {p.ExitCode} koduyla çıktı")));
        });
        return p;
    }

    public static void Terminate(Process p)
    {
        try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch { }
    }
}

public static class Fmt
{
    public static string Size(long bytes)
    {
        if (bytes < 0) return "—";
        string[] u = ["B", "KB", "MB", "GB", "TB"];
        double n = bytes;
        var i = 0;
        while (n >= 1024 && i < u.Length - 1) { n /= 1024; i++; }
        return i == 0 ? $"{n:0} {u[i]}" : $"{n:0.0} {u[i]}";
    }

    public static string Speed(double bps) => bps > 0 ? Size((long)bps) + "/s" : "";

    public static string Eta(DownloadItem item)
    {
        if (item.TotalBytes <= 0 || item.Speed <= 1) return "";
        var s = TimeSpan.FromSeconds((item.TotalBytes - item.ReceivedBytes) / item.Speed);
        return s.TotalHours >= 1 ? $"{(int)s.TotalHours}:{s.Minutes:00}:{s.Seconds:00}" : $"{s.Minutes}:{s.Seconds:00}";
    }
}
