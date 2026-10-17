using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace MCDM;

/// yt-dlp wrapper. Prefers a user-installed / bundled copy (Tools\ next to the exe), then PATH.
public static partial class VideoDownloader
{
    public static string ToolsDirectory => Path.Combine(AppContext.BaseDirectory, "Tools");

    static string? Find(string exeName, params string?[] candidates)
    {
        foreach (var c in candidates)
            if (!string.IsNullOrWhiteSpace(c) && File.Exists(c)) return c;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var p = Path.Combine(dir.Trim('"'), exeName);
                if (File.Exists(p)) return p;
            }
            catch { }
        }
        return null;
    }

    public static string? LocateYtDlp(string custom) =>
        Find("yt-dlp.exe", custom, ToolInstaller.UserYtDlpPath, Path.Combine(ToolsDirectory, "yt-dlp.exe"));

    public static string? LocateFfmpeg() => Find("ffmpeg.exe", Path.Combine(ToolsDirectory, "ffmpeg.exe"));

    /// deno is the JavaScript runtime yt-dlp uses to solve YouTube's n/signature challenges.
    /// Without it YouTube downloads fail or lose formats (see https://github.com/yt-dlp/yt-dlp/wiki/EJS).
    public static string? LocateDeno() => Find("deno.exe", ToolInstaller.UserDenoPath, Path.Combine(ToolsDirectory, "deno.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".deno", "bin", "deno.exe"));

    static bool HostMatches(string host, string domain) => host == domain || host.EndsWith("." + domain);

    public static bool IsYouTube(Uri url)
    {
        var host = url.Host.ToLowerInvariant();
        return new[] { "youtube.com", "youtu.be", "youtube-nocookie.com" }.Any(d => HostMatches(host, d));
    }

    /// YouTube rejects the signed-in clients yt-dlp picks when cookies are passed
    /// ("The page needs to be reloaded", yt-dlp#17389); the same video usually works without cookies.
    public static bool IsSignedInClientFailure(string message) => message.Contains("page needs to be reloaded", StringComparison.OrdinalIgnoreCase);

    public static bool HasCookies(string? itemCookies, string? targetHost)
    {
        if (itemCookies != null && File.Exists(itemCookies)) return true;
        var host = targetHost?.ToLowerInvariant() ?? "";
        return SiteLoginManager.Shared.Domains.Any(d => HostMatches(host, d));
    }

    /// Combines the per-download cookie file (from the browser extension) with the shared site-login cookie file
    /// into one temporary Netscape file. The site-login jar is only attached when the target host belongs to one of
    /// the domains the user signed in to.
    public static string? MergedCookieFile(string? itemCookies, string? targetHost)
    {
        var item = itemCookies != null && File.Exists(itemCookies) ? itemCookies : null;
        var host = targetHost?.ToLowerInvariant() ?? "";
        var site = SiteLoginManager.Shared.Domains.Any(d => HostMatches(host, d)) ? SiteLoginManager.CookieFilePath : null;
        if (item == null || site == null) return item ?? site;
        try
        {
            var tmp = Path.Combine(Path.GetTempPath(), $"mcdm-cookies-{Guid.NewGuid()}.txt");
            File.WriteAllText(tmp, File.ReadAllText(site) + "\n" + File.ReadAllText(item));
            return tmp;
        }
        catch { return item; }
    }

    public readonly record struct Progress(long Downloaded, long Total, double Speed);

    [GeneratedRegex(@"\.f[0-9]+[-a-z0-9]*(?=\.[a-z0-9]+$)")]
    public static partial Regex FormatSuffix();
    [GeneratedRegex(@"\.f[0-9]+[-a-z0-9]*\.(m4a|webm|opus|mp3|aac|ogg)$")]
    private static partial Regex AudioPart();
    [GeneratedRegex(@"\.f[0-9]+[-a-z0-9]*\.[a-z0-9]+$")]
    private static partial Regex AnyPart();

    /// Turns a yt-dlp log line into a user-facing phase description, if it marks a new phase.
    public static string? Stage(string line)
    {
        if (line.StartsWith("[download] Destination:"))
        {
            // yt-dlp names intermediate files <title>.f<formatid>.<ext>
            var lower = line.ToLowerInvariant();
            if (AudioPart().IsMatch(lower)) return L.T("Downloading audio…");
            if (AnyPart().IsMatch(lower)) return L.T("Downloading video…");
            return L.T("Downloading…");
        }
        if (line.StartsWith("[Merger]")) return L.T("Merging video and audio (ffmpeg)…");
        if (line.StartsWith("[VideoRemuxer]") || line.StartsWith("[VideoConvertor]")) return L.T("Converting container (ffmpeg)…");
        if (line.StartsWith("[ExtractAudio]")) return L.T("Extracting audio (ffmpeg)…");
        if (line.StartsWith("MCFMT|"))
        {
            var p = line.Split('|');
            if (p.Length < 6) return null;
            var parts = new List<string>();
            if (p[1] != "NA" && p[1].Length > 0) parts.Add(p[1]);
            if (p[2] != "NA") parts.Add(p[2].ToUpperInvariant());
            if (p[3] != "NA" && p[3] != "none") parts.Add(p[3].Split('.')[0]);
            if (double.TryParse(p[5], CultureInfo.InvariantCulture, out var n) && n > 0) parts.Add("~" + Fmt.Size((long)n));
            return L.T("Selected: %@", string.Join(" · ", parts));
        }
        if (line.Contains("has already been downloaded")) return L.T("File already downloaded");
        return null;
    }

    /// Starts yt-dlp. onFinish receives the final file path (if printed) or the error. Returns null when the process could not start.
    public static Process? Run(string executable, Uri url, string outputDir, string[] formatArgs, Dictionary<string, string> headers,
                               string? cookieFile, bool useCookies,
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
        string[] args =
        [
            "--newline", "--no-playlist", "--no-colors", "--progress", "--no-simulate", "--no-mtime", "--no-quiet",
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
        if (headers.TryGetValue("Referer", out var referer) && referer.Length > 0) { psi.ArgumentList.Add("--referer"); psi.ArgumentList.Add(referer); }
        if (useCookies && MergedCookieFile(cookieFile, url.Host) is { } cf) { psi.ArgumentList.Add("--cookies"); psi.ArgumentList.Add(cf); }
        if (LocateDeno() is { } deno) { psi.ArgumentList.Add("--js-runtimes"); psi.ArgumentList.Add("deno:" + deno); }
        psi.ArgumentList.Add(url.AbsoluteUri);
        psi.Environment["PATH"] = ToolsDirectory + ";" + Environment.GetEnvironmentVariable("PATH");
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        psi.Environment["PYTHONUTF8"] = "1";

        var gate = new object();
        string? finalPath = null, lastError = null;

        void Handle(string raw, bool isError)
        {
            var line = raw.Trim();
            if (line.Length == 0) return;
            if (line.StartsWith("DMP|"))
            {
                var parts = line.Split('|');
                if (parts.Length < 5) return;
                static long Num(string s) => double.TryParse(s, CultureInfo.InvariantCulture, out var d) ? (long)d : -1;
                long total = Num(parts[2]);
                if (total <= 0) total = Num(parts[3]);
                double speed = double.TryParse(parts[4], CultureInfo.InvariantCulture, out var sp) ? Math.Max(0, sp) : 0;
                onProgress(new Progress(Math.Max(0, Num(parts[1])), total, speed));
                return;
            }
            if (Path.IsPathFullyQualified(line) && File.Exists(line)) lock (gate) finalPath = line;
            if (isError && line.StartsWith("ERROR")) lock (gate) lastError = line;
            onLine(line);
        }

        var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) Handle(e.Data, false); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) Handle(e.Data, true); };
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
            await p.WaitForExitAsync();   // also waits for the end of both output streams
            string? path, err;
            lock (gate) { path = finalPath; err = lastError; }
            if (p.ExitCode == 0) onFinish(path, null);
            else onFinish(null, new DownloadFailure(err ?? L.T("yt-dlp exited with code %d", p.ExitCode)));
        });
        return p;
    }
}
