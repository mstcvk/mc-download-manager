using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;

namespace MCDM;

/// Watches the system clipboard for http(s) links and asks the user whether to download them.
/// Also used by the Ctrl+V paste command in the main window.
public static class ClipboardWatcher
{
    [DllImport("user32.dll")]
    static extern uint GetClipboardSequenceNumber();

    static DownloadStore? store;
    static AppSettings? settings;
    static DispatcherTimer? timer;
    static uint lastSequence;
    static readonly List<string> AskedUrls = [];
    static bool prompting;

    static readonly string[] VideoHosts = ["youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "twitter.com", "x.com",
                                           "instagram.com", "tiktok.com", "twitch.tv", "facebook.com", "reddit.com", "bilibili.com"];

    public static void Start(DownloadStore s, AppSettings st)
    {
        store = s;
        settings = st;
        lastSequence = GetClipboardSequenceNumber();
        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) => Poll();
        timer.Start();
    }

    // MARK: - Clipboard polling

    static void Poll()
    {
        if (settings is not { WatchClipboard: true } || prompting) return;
        var seq = GetClipboardSequenceNumber();
        if (seq == lastSequence) return;
        lastSequence = seq;
        string text;
        try
        {
            if (!Clipboard.ContainsText()) return;
            text = Clipboard.GetText();
        }
        catch { return; }   // clipboard locked by another app
        // Only react when the clipboard holds nothing but links, and the links point at files of a captured type.
        if (UrlOnlyContent(text) is not { } onlyUrls) return;
        var exts = settings.CaptureExtensions;
        var urls = onlyUrls.Where(u => CaptureTypes.Matches(u, exts) && !AskedUrls.Contains(u.AbsoluteUri)).ToList();
        if (urls.Count == 0) return;
        Remember(urls);
        Ask(urls, fromClipboard: true);
    }

    /// Called from the Ctrl+V paste command (explicit user action: any http(s) link is accepted).
    public static void HandlePaste(string text)
    {
        if (UrlOnlyContent(text) is not { Count: > 0 } urls) return;
        Remember(urls);
        Ask(urls, fromClipboard: false);
    }

    static void Remember(List<Uri> urls)
    {
        AskedUrls.AddRange(urls.Select(u => u.AbsoluteUri));
        if (AskedUrls.Count > 50) AskedUrls.RemoveRange(0, AskedUrls.Count - 50);
    }

    /// Returns the links if every non-empty line of `text` is a single http(s) URL; null otherwise.
    public static List<Uri>? UrlOnlyContent(string text)
    {
        var lines = text.Split('\n', '\r').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        if (lines.Count == 0 || lines.Count > 50) return null;
        var urls = new List<Uri>();
        foreach (var line in lines)
        {
            if (line.Contains(' ') || !Uri.TryCreate(line, UriKind.Absolute, out var url)
                || url.Scheme is not ("http" or "https") || url.Host.Length == 0) return null;
            if (!urls.Contains(url)) urls.Add(url);
        }
        return urls;
    }

    public static bool LooksLikeVideoPage(Uri url)
    {
        var host = url.Host.ToLowerInvariant();
        if (FileCategories.Detect(Path.GetFileName(url.AbsolutePath), DownloadKind.File) != FileCategory.Other) return false;
        return VideoHosts.Any(h => host == h || host.EndsWith("." + h));
    }

    // MARK: - Prompt

    static void Ask(List<Uri> urls, bool fromClipboard)
    {
        if (store == null) return;
        prompting = true;
        string heading, body;
        if (urls.Count == 1)
        {
            heading = fromClipboard ? L.T("A link was copied. Download it?") : L.T("Download the pasted link?");
            body = urls[0].AbsoluteUri;
        }
        else
        {
            heading = fromClipboard ? L.T("%lld links were copied. Download them?", urls.Count) : L.T("Download the %lld pasted links?", urls.Count);
            body = string.Join("\n", urls.Take(6).Select(u => u.AbsoluteUri)) + (urls.Count > 6 ? "\n…" : "");
        }
        bool preferVideo = urls.All(LooksLikeVideoPage);
        string[] buttons = preferVideo
            ? [L.T("Download Video (yt-dlp)"), L.T("Download as File"), L.T("Ignore")]
            : [L.T("Download"), L.T("Download Video (yt-dlp)"), L.T("Ignore")];
        var (button, stopWatching) = Dialogs.Ask(heading, body, buttons, fromClipboard ? L.T("Stop watching the clipboard") : null);
        prompting = false;
        if (stopWatching && settings != null) settings.WatchClipboard = false;

        DownloadKind? kind = button switch
        {
            0 => preferVideo ? DownloadKind.Video : DownloadKind.File,
            1 => preferVideo ? DownloadKind.File : DownloadKind.Video,
            _ => null,
        };
        if (kind == null) return;
        foreach (var url in urls) store.Add(new NewDownloadRequest(url) { Kind = kind.Value });
    }
}
