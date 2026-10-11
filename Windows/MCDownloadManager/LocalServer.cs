using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace MCDownloadManager;

public sealed record HttpRequest(string Method, string Path, Dictionary<string, string> Headers, byte[] Body)
{
    public string? Header(string name) => Headers.TryGetValue(name, out var v) ? v : null;
}

public sealed record HttpResponse(int Status, object Json)
{
    public static HttpResponse Ok(object json) => new(200, json);
    public static HttpResponse Error(string message, int status) => new(status, new Dictionary<string, object> { ["ok"] = false, ["error"] = message });
}

/// Small HTTP server on 127.0.0.1 that the browser extensions POST to. A raw TcpListener rather than
/// HttpListener: http.sys rejects 127.0.0.1 for non-admin users unless a URL ACL is registered.
public sealed class LocalServer(int port, Func<HttpRequest, Task<HttpResponse>> handler, Func<string?, bool> corsAllowed) : IDisposable
{
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    public int Port { get; } = port;

    public void Start()
    {
        var l = new TcpListener(IPAddress.Loopback, Port);
        l.Start();
        _listener = l;
        _cts = new CancellationTokenSource();
        _ = AcceptLoop(l, _cts.Token);
    }

    public void Dispose()
    {
        _cts?.Cancel();
        try { _listener?.Stop(); } catch { }
        _listener = null;
    }

    private async Task AcceptLoop(TcpListener l, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await l.AcceptTcpClientAsync(ct); }
            catch { break; }
            _ = Task.Run(() => Serve(client));
        }
    }

    private async Task Serve(TcpClient client)
    {
        using (client)
        {
            var stream = client.GetStream();
            var buffer = new MemoryStream();
            var chunk = new byte[1 << 16];
            HttpRequest? req = null;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            while (req == null)
            {
                int n;
                try { n = await stream.ReadAsync(chunk, timeout.Token); }
                catch { return; }
                if (n == 0) return;
                buffer.Write(chunk, 0, n);
                if (buffer.Length > 16_000_000) return;
                req = Parse(buffer.GetBuffer().AsSpan(0, (int)buffer.Length));
            }
            HttpResponse resp;
            try { resp = await handler(req); }
            catch (Exception e) { resp = HttpResponse.Error(e.Message, 500); }
            try { await Send(stream, resp, req.Header("origin")); } catch { }
        }
    }

    public static HttpRequest? Parse(ReadOnlySpan<byte> data)
    {
        var headerEnd = data.IndexOf("\r\n\r\n"u8);
        if (headerEnd < 0) return null;
        var head = Encoding.UTF8.GetString(data[..headerEnd]);
        var lines = head.Split("\r\n");
        var reqLine = lines[0].Split(' ');
        if (reqLine.Length < 2) return null;
        var headers = new Dictionary<string, string>();
        foreach (var l in lines.Skip(1))
        {
            var c = l.IndexOf(':');
            if (c <= 0) continue;
            headers[l[..c].Trim().ToLowerInvariant()] = l[(c + 1)..].Trim();
        }
        _ = int.TryParse(headers.GetValueOrDefault("content-length"), out var length);
        if (length < 0) length = 0;
        var bodyStart = headerEnd + 4;
        if (data.Length - bodyStart < length) return null;
        return new HttpRequest(reqLine[0].ToUpperInvariant(), reqLine[1], headers, data.Slice(bodyStart, length).ToArray());
    }

    private async Task Send(NetworkStream stream, HttpResponse resp, string? origin)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(resp.Json);
        var head = new StringBuilder()
            .Append($"HTTP/1.1 {resp.Status} {(resp.Status == 200 ? "OK" : "Error")}\r\n")
            .Append("Content-Type: application/json; charset=utf-8\r\n")
            .Append($"Content-Length: {body.Length}\r\n")
            .Append("Cache-Control: no-store\r\n")
            .Append("X-Content-Type-Options: nosniff\r\n");
        // CORS headers only for allowed extension origins; ordinary web pages get none.
        if (origin != null && corsAllowed(origin))
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
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head.ToString()));
        await stream.WriteAsync(body);
    }
}
