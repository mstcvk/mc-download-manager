using System.Diagnostics;
using System.Security.Cryptography;

namespace MCDownloadManager;

/// Installs/updates yt-dlp.exe from its official GitHub release into %LOCALAPPDATA%\MC Download Manager\bin.
/// The download is checked against the release's SHA2-256SUMS before it replaces the current copy.
public static class ToolInstaller
{
    private const string ReleaseBase = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/";

    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(10) };

    public static string YtDlpPath => Path.Combine(VideoDownloader.ToolsDirectory, "yt-dlp.exe");

    public static async Task<string> InstallYtDlp(IProgress<double>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(VideoDownloader.ToolsDirectory);
        Client.DefaultRequestHeaders.UserAgent.TryParseAdd("MCDownloadManager/" + BridgeController.Version);

        var sums = await Client.GetStringAsync(ReleaseBase + "SHA2-256SUMS", ct);
        var expected = sums.Split('\n')
            .Select(l => l.Trim().Split(' ', 2, StringSplitOptions.RemoveEmptyEntries))
            .FirstOrDefault(p => p.Length == 2 && p[1].Trim().TrimStart('*') == "yt-dlp.exe")?[0];
        if (expected == null) throw new DownloadFailure(L.T("Could not fetch the checksum for verification.", "Doğrulama için sağlama toplamı alınamadı."));

        var tmp = YtDlpPath + ".download";
        using (var resp = await Client.GetAsync(ReleaseBase + "yt-dlp.exe", HttpCompletionOption.ResponseHeadersRead, ct))
        {
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? -1;
            await using var body = await resp.Content.ReadAsStreamAsync(ct);
            await using var file = File.Create(tmp);
            var buffer = new byte[1 << 16];
            long got = 0;
            int n;
            while ((n = await body.ReadAsync(buffer, ct)) > 0)
            {
                await file.WriteAsync(buffer.AsMemory(0, n), ct);
                got += n;
                if (total > 0) progress?.Report((double)got / total);
            }
        }

        string actual;
        await using (var f = File.OpenRead(tmp))
            actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(f, ct));
        if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(tmp);
            throw new DownloadFailure(L.T("The downloaded yt-dlp does not match its published checksum.", "İndirilen yt-dlp yayınlanan sağlama toplamıyla eşleşmiyor."));
        }
        File.Move(tmp, YtDlpPath, overwrite: true);
        return Version(YtDlpPath) ?? "?";
    }

    public static string? Version(string exe)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(exe, "--version")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            });
            if (p == null) return null;
            var v = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(15000);
            return v.Length > 0 ? v : null;
        }
        catch { return null; }
    }
}
