using System.Text.Json;

namespace MCDownloadManager;

/// Runs the local HTTP bridge and turns extension requests into DownloadStore calls.
/// Same protocol as the macOS app (Server/ServerController.swift), so the extension works unchanged.
public sealed class BridgeController : IDisposable
{
    public const string Version = "1.3.0";

    private readonly DownloadStore _store;
    private readonly AppSettings _settings;
    private readonly SynchronizationContext _ui;
    private LocalServer? _server;

    public string StatusText { get; private set; } = L.T("Not started", "Başlatılmadı");
    public bool Running { get; private set; }
    public event Action? StatusChanged;

    /// Last time each browser's extension talked to the bridge.
    public Dictionary<string, DateTime> ExtensionConnections { get; } = new();

    public BridgeController(DownloadStore store, AppSettings settings, SynchronizationContext ui)
    {
        _store = store;
        _settings = settings;
        _ui = ui;
    }

    public void Start()
    {
        _server?.Dispose();
        var port = _settings.ClampedPort;
        var s = new LocalServer(port, HandleOnUi, OriginAllowed);
        try
        {
            s.Start();
            _server = s;
            Running = true;
            StatusText = L.T($"Listening on 127.0.0.1:{port}", $"127.0.0.1:{port} dinleniyor");
        }
        catch (Exception e)
        {
            Running = false;
            StatusText = L.T($"Error: {e.Message} (port {port} may be in use)", $"Hata: {e.Message} ({port} portu kullanımda olabilir)");
        }
        StatusChanged?.Invoke();
    }

    public void Dispose() => _server?.Dispose();

    /// Only browser extensions may talk to the bridge. Requests without an Origin, with an empty Origin or
    /// with the opaque "null" origin (sandboxed iframes, data: pages) are rejected.
    public static bool OriginAllowed(string? origin)
    {
        if (string.IsNullOrEmpty(origin) || origin == "null") return false;
        return origin.StartsWith("chrome-extension://", StringComparison.Ordinal)
            || origin.StartsWith("safari-web-extension://", StringComparison.Ordinal)
            || origin.StartsWith("moz-extension://", StringComparison.Ordinal);
    }

    /// Extension requests either carry an extension Origin or — when Chrome omits the Origin header for GETs
    /// covered by host permissions — no Origin at all plus the X-MCDM-Extension header. A web page cannot produce
    /// the second form: custom headers force a CORS preflight whose web Origin is rejected here.
    public static bool ExtensionRequest(HttpRequest req)
    {
        var origin = req.Header("origin");
        if (OriginAllowed(origin)) return true;
        return origin == null && !string.IsNullOrEmpty(req.Header("x-mcdm-extension"));
    }

    private bool HostAllowed(string? host)
    {
        if (host == null) return false;
        host = host.ToLowerInvariant();
        var port = _settings.ClampedPort;
        return host == $"127.0.0.1:{port}" || host == $"localhost:{port}" || host == $"[::1]:{port}";
    }

    /// The store is single-threaded (UI thread); requests are marshalled onto it.
    private Task<HttpResponse> HandleOnUi(HttpRequest req)
    {
        var tcs = new TaskCompletionSource<HttpResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        _ui.Post(_ =>
        {
            try { tcs.SetResult(Handle(req)); }
            catch (Exception e) { tcs.SetResult(HttpResponse.Error(e.Message, 500)); }
        }, null);
        return tcs.Task;
    }

    private void NoteConnection(HttpRequest req)
    {
        var browser = "other";
        var origin = req.Header("origin");
        if (origin != null)
        {
            if (origin.StartsWith("chrome-extension://")) browser = "chrome";
            else if (origin.StartsWith("moz-extension://")) browser = "firefox";
        }
        var h = req.Header("x-mcdm-extension")?.ToLowerInvariant();
        if (h is "chrome" or "brave" or "edge" or "firefox") browser = h;
        ExtensionConnections[browser] = DateTime.Now;

        // Chromium extension ids may call the native host that launches the app (see NativeHostRegistry).
        var id = req.Header("x-mcdm-extension-id");
        if (origin != null && origin.StartsWith("chrome-extension://"))
            id = origin["chrome-extension://".Length..].Split('/')[0];
        if (id != null) NativeHostRegistry.NoteExtensionId(id.ToLowerInvariant());
    }

    private HttpResponse Handle(HttpRequest req)
    {
        if (!ExtensionRequest(req) || !HostAllowed(req.Header("host")))
            return HttpResponse.Error("forbidden", 403);
        if (req.Method == "OPTIONS") return HttpResponse.Ok(new { ok = true });
        NoteConnection(req);
        var path = req.Path.Split('?', 2)[0];

        switch (req.Method, path)
        {
            case ("GET", "/ping"):
                return HttpResponse.Ok(new Dictionary<string, object>
                {
                    ["ok"] = true,
                    ["app"] = "MCDownloadManager",
                    ["platform"] = "windows",
                    ["version"] = Version,
                    ["ytdlp"] = VideoDownloader.LocateYtDlp(_settings.YtdlpPath) != null,
                    ["active"] = _store.Items.Count(i => i.State.IsActive()),
                    ["captureExtensions"] = _settings.CaptureExtensions,
                });

            case ("GET", "/downloads"):
                return HttpResponse.Ok(new Dictionary<string, object>
                {
                    ["ok"] = true,
                    ["items"] = _store.Items.Take(50).Select(i => new Dictionary<string, object?>
                    {
                        ["id"] = i.Id.ToString().ToUpperInvariant(),
                        ["name"] = i.FileName,
                        ["state"] = i.State.Wire(),
                        ["progress"] = i.Progress,
                        ["speed"] = i.Speed,
                        ["total"] = i.TotalBytes,
                        ["received"] = i.ReceivedBytes,
                        ["stage"] = i.Stage,
                        ["error"] = i.ErrorMessage,
                    }).ToList(),
                });

            case ("POST", "/download"):
                return AddDownload(req.Body);

            case ("POST", "/action"):
            {
                try
                {
                    using var doc = JsonDocument.Parse(req.Body);
                    var root = doc.RootElement;
                    if (!Guid.TryParse(Str(root, "id"), out var id) || Str(root, "action") is not { } action)
                        return HttpResponse.Error("id and action required", 400);
                    switch (action)
                    {
                        case "pause": _store.Pause(id); break;
                        case "resume": _store.Resume(id); break;
                        case "cancel": _store.Cancel(id); break;
                        case "remove": _store.Remove(id); break;
                        default: return HttpResponse.Error("unknown action", 400);
                    }
                    return HttpResponse.Ok(new { ok = true });
                }
                catch (JsonException) { return HttpResponse.Error("id and action required", 400); }
            }

            default:
                return HttpResponse.Error("not found", 404);
        }
    }

    private HttpResponse AddDownload(byte[] body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            var o = doc.RootElement;
            if (Str(o, "url") is not { } urlStr || !Uri.TryCreate(urlStr, UriKind.Absolute, out var url)
                || (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps))
                return HttpResponse.Error("invalid url", 400);

            var r = new NewDownloadRequest(url)
            {
                FileName = Str(o, "filename"),
                Referer = Str(o, "referer"),
                UserAgent = Str(o, "userAgent"),
                CookieHeader = Str(o, "cookieHeader"),
                Kind = Str(o, "kind") == "video" ? DownloadKind.Video : DownloadKind.File,
            };
            if (o.TryGetProperty("segments", out var seg) && seg.ValueKind == JsonValueKind.Number && seg.TryGetInt32(out var n))
                r.Segments = n;
            if (o.TryGetProperty("headers", out var hs) && hs.ValueKind == JsonValueKind.Object)
                foreach (var p in hs.EnumerateObject())
                    if (p.Value.ValueKind == JsonValueKind.String) r.ExtraHeaders[p.Name] = p.Value.GetString()!;
            if (o.TryGetProperty("cookies", out var cs) && cs.ValueKind == JsonValueKind.Array)
            {
                foreach (var c in cs.EnumerateArray())
                {
                    if (c.ValueKind != JsonValueKind.Object || Str(c, "name") is not { } name || Str(c, "value") is not { } value || Str(c, "domain") is not { } domain)
                        continue;
                    r.Cookies.Add(new BrowserCookie(name, value, domain, Str(c, "path") ?? "/",
                        c.TryGetProperty("secure", out var s) && s.ValueKind == JsonValueKind.True,
                        c.TryGetProperty("expirationDate", out var e) && e.ValueKind == JsonValueKind.Number ? (long)e.GetDouble() : 0));
                }
            }
            var item = _store.Add(r);
            return HttpResponse.Ok(new { ok = true, id = item.Id.ToString().ToUpperInvariant() });
        }
        catch (JsonException)
        {
            return HttpResponse.Error("invalid url", 400);
        }
    }

    private static string? Str(JsonElement o, string name) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
