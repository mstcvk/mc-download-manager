using System.ComponentModel;
using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows;

namespace MCDM;

/// Downloads the latest yt-dlp (and deno) from GitHub into %APPDATA% so the app can install them when missing and keep
/// them current (YouTube changes break old yt-dlp builds often).
public sealed partial class ToolInstaller : INotifyPropertyChanged
{
    public static ToolInstaller Shared { get; } = new();

    public bool Busy { get; private set; }
    public double Progress { get; private set; }
    public string? Message { get; private set; }
    public string? InstalledVersion { get; private set; }
    public string? DenoVersion { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    static readonly Uri YtDlpUrl = new("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe");
    static readonly Uri DenoZipUrl = new("https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip");
    /// Approximate download size, shown in the install prompt.
    public const string DenoDownloadSize = "~45 MB";

    public static string BinDirectory => Path.Combine(AppSettings.SupportDir, "bin");
    public static string UserYtDlpPath => Path.Combine(BinDirectory, "yt-dlp.exe");
    public static string UserDenoPath => Path.Combine(BinDirectory, "deno.exe");

    /// `<tool> --version` for the given executable (cached per path).
    readonly Dictionary<string, string> versionCache = [];

    string? Version(string path)
    {
        lock (versionCache) if (versionCache.TryGetValue(path, out var v)) return v;
        try
        {
            using var p = Process.Start(new ProcessStartInfo(path, "--version")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            })!;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(15000);
            // deno prints three lines (deno, v8, typescript); keep the first.
            var v = output.Split('\n').FirstOrDefault()?.Trim();
            if (string.IsNullOrEmpty(v)) return null;
            lock (versionCache) versionCache[path] = v;
            return v;
        }
        catch { return null; }
    }

    public void RefreshVersion(string custom)
    {
        Task.Run(() =>
        {
            var v = VideoDownloader.LocateYtDlp(custom) is { } y ? Version(y) : null;
            var d = VideoDownloader.LocateDeno() is { } dn ? Version(dn) : null;
            Ui(() => { InstalledVersion = v; DenoVersion = d; Changed(); });
        });
    }

    static void Ui(Action a) => Application.Current.Dispatcher.BeginInvoke(a);

    /// Downloads to `target` with the segmented downloader; progress feeds the Settings bar.
    void Download(Uri url, string target, Action<Exception?> done)
    {
        Directory.CreateDirectory(BinDirectory);
        var dl = new SegmentedDownloader(new SegmentedDownloader.Configuration
        {
            Url = url, Headers = new() { ["User-Agent"] = DownloadStore.DefaultUserAgent }, PartPath = target, SegmentCount = 4,
        });
        long total = -1;
        dl.OnProbe = p => total = p.TotalBytes;
        dl.OnProgress = (received, _) => Ui(() => { if (total > 0) { Progress = (double)received / total; Changed(); } });
        dl.OnFinish = e => Ui(() => done(e));
        dl.Start();
    }

    void Begin(string message)
    {
        Busy = true;
        Progress = 0;
        Message = message;
        Changed();
    }

    /// Downloads yt-dlp.exe, verifies it runs, and installs it to %APPDATA%.
    public void InstallOrUpdateYtDlp(Action<Exception?> completion)
    {
        if (Busy) return;
        Begin(L.T("Downloading yt-dlp…"));
        var tmp = Path.Combine(BinDirectory, ".yt-dlp.download");
        Download(YtDlpUrl, tmp, error =>
        {
            if (error != null) { Finish(error, null, isDeno: false, completion); return; }
            Message = L.T("Verifying…");
            Changed();
            Task.Run(() =>
            {
                Exception? e = null;
                string? v = null;
                try
                {
                    var exe = tmp + ".exe";
                    File.Move(tmp, exe, true);
                    lock (versionCache) versionCache.Remove(exe);
                    v = Version(exe);
                    if (string.IsNullOrEmpty(v))
                    {
                        File.Delete(exe);
                        throw new DownloadFailure(L.T("The downloaded yt-dlp binary could not be executed."));
                    }
                    File.Move(exe, UserYtDlpPath, true);
                    File.SetAttributes(UserYtDlpPath, FileAttributes.Normal);   // part files are created hidden
                    lock (versionCache) versionCache[UserYtDlpPath] = v;
                }
                catch (Exception ex) { e = ex; }
                Ui(() => Finish(e, v, isDeno: false, completion));
            });
        });
    }

    // MARK: - deno (JavaScript runtime yt-dlp needs for YouTube's signature/n challenges)

    /// Downloads the latest deno release zip, checks it against the published SHA-256, unpacks it and installs it.
    public void InstallDeno(Action<Exception?> completion)
    {
        if (Busy)
        {
            completion(new DownloadFailure(L.T("Another tool install is in progress.")));
            return;
        }
        Begin(L.T("Downloading deno…"));
        var zip = Path.Combine(BinDirectory, ".deno.zip");
        Download(DenoZipUrl, zip, error =>
        {
            if (error != null)
            {
                try { File.Delete(zip); } catch { }
                Finish(error, null, isDeno: true, completion);
                return;
            }
            Message = L.T("Verifying…");
            Changed();
            Task.Run(async () =>
            {
                Exception? e = null;
                string? v = null;
                var staging = Path.Combine(BinDirectory, ".deno-unpack");
                try
                {
                    await VerifyChecksum(zip, new Uri(DenoZipUrl.AbsoluteUri + ".sha256sum"));
                    if (Directory.Exists(staging)) Directory.Delete(staging, true);
                    try { ZipFile.ExtractToDirectory(zip, staging); }
                    catch { throw new DownloadFailure(L.T("The deno archive could not be unpacked.")); }
                    var bin = Path.Combine(staging, "deno.exe");
                    if (!File.Exists(bin)) throw new DownloadFailure(L.T("The deno archive could not be unpacked."));
                    v = Version(bin);
                    if (v == null || !v.StartsWith("deno ")) throw new DownloadFailure(L.T("The downloaded deno binary could not be executed."));
                    File.Move(bin, UserDenoPath, true);
                    lock (versionCache) versionCache[UserDenoPath] = v;
                }
                catch (Exception ex) { e = ex; }
                finally
                {
                    try { File.Delete(zip); } catch { }
                    try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch { }
                }
                Ui(() => Finish(e, v, isDeno: true, completion));
            });
        });
    }

    [GeneratedRegex(@"\b[0-9a-fA-F]{64}\b")]
    private static partial Regex Sha256Token();

    /// Compares the file's SHA-256 with the hash in the published checksum file (either `<hash>  <name>` or the
    /// PowerShell Get-FileHash table deno uses for its Windows builds).
    static async Task VerifyChecksum(string file, Uri sumUrl)
    {
        string? expected = null;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd(DownloadStore.DefaultUserAgent);
            expected = Sha256Token().Match(await http.GetStringAsync(sumUrl)).Value.ToLowerInvariant();
        }
        catch { }
        if (string.IsNullOrEmpty(expected)) throw new DownloadFailure(L.T("Could not fetch the checksum for verification."));
        await using var s = File.OpenRead(file);
        var actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(s));
        if (actual != expected) throw new DownloadFailure(L.T("Checksum mismatch; the download was discarded."));
    }

    void Finish(Exception? error, string? version, bool isDeno, Action<Exception?> completion)
    {
        Busy = false;
        Progress = 0;
        if (error == null)
        {
            if (isDeno) { DenoVersion = version; Message = L.T("%@ installed.", version ?? "deno"); }
            else { InstalledVersion = version; Message = L.T("yt-dlp %@ installed.", version ?? ""); }
        }
        else
        {
            Message = L.T("Install failed: %@", error.Message);
        }
        Changed();
        completion(error);
    }
}
