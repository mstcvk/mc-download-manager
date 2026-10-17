using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Threading;

namespace MCDM;

public sealed record HttpRequest(string Method, string Path, Dictionary<string, string> Headers, byte[] Body);
public sealed record HttpResponse(int Status, object Json);

/// Small HTTP server on 127.0.0.1. Browser extensions POST downloads here.
public sealed class LocalServer(int port, Func<HttpRequest, Task<HttpResponse>> handler, Func<string?, bool> allowedOrigin)
{
    TcpListener? listener;

    public void Start()
    {
        var l = new TcpListener(IPAddress.Loopback, port) { ExclusiveAddressUse = true };
        l.Start();
        listener = l;
        _ = AcceptLoop(l);
    }

    public void Stop()
    {
        try { listener?.Stop(); } catch { }
        listener = null;
    }

    async Task AcceptLoop(TcpListener l)
    {
        while (true)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(); }
            catch { return; }
            _ = Serve(c);
        }
    }

    async Task Serve(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                var buf = new List<byte>();
                var chunk = new byte[65536];
                HttpRequest? req;
                while ((req = Parse(buf.ToArray())) == null)
                {
                    int n = await stream.ReadAsync(chunk, timeout.Token);
                    if (n == 0 || buf.Count > 16_000_000) return;
                    buf.AddRange(chunk.AsSpan(0, n));
                }
                var resp = await handler(req);
                var bytes = Encode(resp, req.Headers.GetValueOrDefault("origin"));
                await stream.WriteAsync(bytes, timeout.Token);
            }
            catch { }
        }
    }

    public static HttpRequest? Parse(byte[] data)
    {
        int headerEnd = data.AsSpan().IndexOf("\r\n\r\n"u8);
        if (headerEnd < 0) return null;
        var lines = Encoding.UTF8.GetString(data, 0, headerEnd).Split("\r\n");
        var reqLine = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (reqLine.Length < 2) return null;
        var headers = new Dictionary<string, string>();
        foreach (var l in lines.Skip(1))
        {
            int c = l.IndexOf(':');
            if (c > 0) headers[l[..c].ToLowerInvariant()] = l[(c + 1)..].Trim();
        }
        int length = int.TryParse(headers.GetValueOrDefault("content-length"), out var n) ? n : 0;
        int bodyStart = headerEnd + 4;
        if (data.Length - bodyStart < length) return null;
        return new HttpRequest(reqLine[0].ToUpperInvariant(), reqLine[1], headers, data[bodyStart..(bodyStart + length)]);
    }

    byte[] Encode(HttpResponse resp, string? origin)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(resp.Json);
        var head = new StringBuilder()
            .Append($"HTTP/1.1 {resp.Status} {(resp.Status == 200 ? "OK" : "Error")}\r\n")
            .Append("Content-Type: application/json; charset=utf-8\r\n")
            .Append($"Content-Length: {body.Length}\r\n")
            .Append("Cache-Control: no-store\r\n")
            .Append("X-Content-Type-Options: nosniff\r\n");
        // CORS headers only for allowed extension origins; ordinary web pages get none.
        if (origin != null && allowedOrigin(origin))
        {
            head.Append($"Access-Control-Allow-Origin: {origin}\r\n")
                .Append("Vary: Origin\r\n")
                .Append("Access-Control-Allow-Headers: Content-Type, X-MCDM-Extension, X-MCDM-Extension-Id\r\n")
                .Append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n")
                // Chrome Private/Local Network Access preflights for loopback targets.
                .Append("Access-Control-Allow-Private-Network: true\r\n")
                .Append("Access-Control-Allow-Local-Network: true\r\n");
        }
        head.Append("Connection: close\r\n\r\n");
        return [.. Encoding.UTF8.GetBytes(head.ToString()), .. body];
    }
}

/// Runs the local HTTP bridge and turns its requests into DownloadStore calls.
public sealed class ServerController : INotifyPropertyChanged
{
    public string StatusText { get; private set; } = L.T("Not started");
    public bool Running { get; private set; }
    /// Last time each browser's extension talked to the bridge (keys: chrome, edge, brave, firefox, other).
    public Dictionary<string, DateTime> ExtensionConnections { get; } = [];
    public event PropertyChangedEventHandler? PropertyChanged;

    public static string Version => typeof(ServerController).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.0.0";

    readonly DownloadStore store;
    readonly AppSettings settings;
    LocalServer? server;
    readonly DispatcherTimer restartTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    public ServerController(DownloadStore store, AppSettings settings)
    {
        this.store = store;
        this.settings = settings;
        Start();
        restartTimer.Tick += (_, _) => { restartTimer.Stop(); Start(); };
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(AppSettings.ServerPort)) return;
            restartTimer.Stop();
            restartTimer.Start();
        };
    }

    public bool IsExtensionConnected(string browser, double withinSeconds = 120) =>
        ExtensionConnections.TryGetValue(browser, out var d) && (DateTime.Now - d).TotalSeconds < withinSeconds;

    int Port => Math.Clamp(settings.ServerPort, 1024, 65535);

    void SetStatus(bool running, string text)
    {
        Running = running;
        StatusText = text;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    public void Start()
    {
        server?.Stop();
        int port = Port;
        var dispatcher = Dispatcher.CurrentDispatcher;
        var s = new LocalServer(port, async req => await dispatcher.InvokeAsync(() => Handle(req)), OriginAllowed);
        try
        {
            s.Start();
            server = s;
            SetStatus(true, L.T("Listening on 127.0.0.1:%@", port.ToString()));
        }
        catch (SocketException e)
        {
            SetStatus(false, L.T("Error: %1$@ (port %2$@ may be in use)", e.Message, port.ToString()));
        }
        catch (Exception e)
        {
            SetStatus(false, L.T("Could not start: %@", e.Message));
        }
    }

    /// Only browser extensions may talk to the bridge. Requests without an Origin, with an empty Origin or with the
    /// opaque "null" origin (sandboxed iframes, data: pages) are rejected, so ordinary web pages cannot drive the app.
    public static bool OriginAllowed(string? origin) =>
        !string.IsNullOrEmpty(origin) && origin != "null"
        && (origin.StartsWith("chrome-extension://") || origin.StartsWith("moz-extension://") || origin.StartsWith("safari-web-extension://"));

    /// Extension requests either carry an extension Origin (POST) or — when Chrome omits the Origin header for GETs
    /// covered by host permissions — no Origin at all plus the X-MCDM-Extension header. A web page cannot produce the
    /// second form: custom headers force a CORS preflight, and the preflight's Origin is a web origin that is rejected here.
    public static bool ExtensionRequest(HttpRequest req)
    {
        var origin = req.Headers.GetValueOrDefault("origin");
        if (OriginAllowed(origin)) return true;
        return origin == null && !string.IsNullOrEmpty(req.Headers.GetValueOrDefault("x-mcdm-extension"));
    }

    bool HostAllowed(string? host)
    {
        host = host?.ToLowerInvariant();
        return host == $"127.0.0.1:{Port}" || host == $"localhost:{Port}" || host == $"[::1]:{Port}";
    }

    void NoteConnection(HttpRequest req)
    {
        var browser = "other";
        var origin = req.Headers.GetValueOrDefault("origin");
        if (origin != null)
        {
            if (origin.StartsWith("chrome-extension://")) browser = "chrome";
            else if (origin.StartsWith("moz-extension://")) browser = "firefox";
        }
        var h = req.Headers.GetValueOrDefault("x-mcdm-extension")?.ToLowerInvariant();
        if (h is "chrome" or "brave" or "edge" or "firefox" or "safari") browser = h;
        int q = req.Path.IndexOf('?');
        if (q >= 0)
            foreach (var pair in req.Path[(q + 1)..].Split('&'))
            {
                var kv = pair.Split('=', 2);
                if (kv.Length == 2 && kv[0] == "browser") browser = kv[1].ToLowerInvariant();
            }
        // Chromium extension ids may call the native host that launches the app (see NativeHost).
        var extensionId = req.Headers.GetValueOrDefault("x-mcdm-extension-id");
        if (origin != null && origin.StartsWith("chrome-extension://"))
            extensionId = new string(origin["chrome-extension://".Length..].TakeWhile(c => c != '/').ToArray());
        if (extensionId?.ToLowerInvariant() is { } id && NativeHost.IsValidChromiumId(id))
        {
            NativeHost.NoteExtensionId(id);
            // Brave reports itself as Chrome; the id of a wizard-prepared folder names the browser exactly.
            if (UnpackedIds.Value.TryGetValue(id, out var kind)) browser = kind;
        }
        ExtensionConnections[browser] = DateTime.Now;
    }

    static readonly Lazy<Dictionary<string, string>> UnpackedIds = new(() =>
        BrowserIntegration.All.Where(k => k.IsChromium)
            .ToDictionary(k => NativeHost.UnpackedExtensionId(BrowserIntegration.PluginFolder(k)), k => k.Id));

    HttpResponse Json(object o, int status = 200) => new(status, o);

    HttpResponse Handle(HttpRequest req)
    {
        if (!ExtensionRequest(req) || !HostAllowed(req.Headers.GetValueOrDefault("host")))
            return Json(new { ok = false, error = "forbidden" }, 403);
        if (req.Method == "OPTIONS") return Json(new { ok = true });
        NoteConnection(req);
        var path = req.Path.Split('?', 2)[0];

        switch (req.Method, path)
        {
            case ("GET", "/ping"):
                return Json(new
                {
                    ok = true,
                    app = "MCDownloadManager",
                    version = Version,
                    ytdlp = VideoDownloader.LocateYtDlp(settings.YtdlpPath) != null,
                    active = store.ActiveCount,
                    captureExtensions = settings.CaptureExtensions,
                });

            case ("GET", "/downloads"):
                return Json(new
                {
                    ok = true,
                    items = store.Items.Take(50).Select(i => new
                    {
                        id = i.Id.ToString().ToUpperInvariant(),
                        name = i.FileName,
                        state = i.State.Raw(),
                        progress = i.Progress,
                        speed = i.Speed,
                        total = i.TotalBytes,
                        received = i.ReceivedBytes,
                        stage = i.Stage,
                    }),
                });

            case ("POST", "/download"):
            {
                JsonObject? obj = null;
                try { obj = JsonNode.Parse(req.Body) as JsonObject; } catch { }
                var urlStr = Str(obj, "url");
                if (urlStr == null || !Uri.TryCreate(urlStr, UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https"))
                    return Json(new { ok = false, error = "invalid url" }, 400);
                var r = new NewDownloadRequest(url)
                {
                    FileName = Str(obj, "filename"),
                    Referer = Str(obj, "referer"),
                    UserAgent = Str(obj, "userAgent"),
                    CookieHeader = Str(obj, "cookieHeader"),
                    Kind = Str(obj, "kind") == "video" ? DownloadKind.Video : DownloadKind.File,
                };
                if (obj!["cookies"] is JsonArray cookies)
                    r.Cookies = cookies.OfType<JsonObject>().Select(c => new BrowserCookie(
                        Str(c, "name") ?? "", Str(c, "value") ?? "", Str(c, "domain") ?? "", Str(c, "path") ?? "/",
                        c["secure"] is JsonValue sv && sv.TryGetValue<bool>(out var sec) && sec,
                        c["expirationDate"] is JsonValue ev && ev.TryGetValue<double>(out var exp) ? exp : 0)).ToList();
                if (obj["headers"] is JsonObject hdrs)
                    foreach (var (k, v) in hdrs) if (v is JsonValue jv && jv.TryGetValue<string>(out var s)) r.ExtraHeaders[k] = s;
                if (obj["segments"] is JsonValue seg && seg.TryGetValue<int>(out var segments)) r.Segments = segments;
                var item = store.Add(r);
                return Json(new { ok = true, id = item.Id.ToString().ToUpperInvariant() });
            }

            case ("POST", "/action"):
            {
                JsonObject? obj = null;
                try { obj = JsonNode.Parse(req.Body) as JsonObject; } catch { }
                if (!Guid.TryParse(Str(obj, "id"), out var id) || Str(obj, "action") is not { } action)
                    return Json(new { ok = false, error = "id and action required" }, 400);
                switch (action)
                {
                    case "pause": store.Pause(id); break;
                    case "resume": store.Resume(id); break;
                    case "cancel": store.Cancel(id); break;
                    case "remove": store.Remove(id); break;
                    default: return Json(new { ok = false, error = "unknown action" }, 400);
                }
                return Json(new { ok = true });
            }

            default:
                return Json(new { ok = false, error = "not found" }, 404);
        }
    }

    static string? Str(JsonObject? o, string key) => o?[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
}
