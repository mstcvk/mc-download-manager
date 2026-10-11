using System.Net;
using System.Net.Http.Headers;
using Microsoft.Win32.SafeHandles;

namespace MCDownloadManager;

public sealed record ProbeResult(long TotalBytes, bool SupportsRanges, string? SuggestedFileName, string? ContentType, Uri? FinalUrl);

/// Downloads one URL with HTTP Range requests split over several connections into a part file.
/// Falls back to a single stream when the server has no Range support; on 429/503 it lowers the number of
/// parallel connections. Callbacks run on thread-pool threads.
public sealed class SegmentedDownloader
{
    public sealed record Configuration(Uri Url, Dictionary<string, string> Headers, string PartPath, int SegmentCount)
    {
        public List<SegmentInfo>? ResumeSegments { get; init; }
        public long ResumeTotal { get; init; } = -1;
    }

    public Action<ProbeResult>? OnProbe;
    public Action<long, List<SegmentInfo>>? OnProgress;
    /// null = success.
    public Action<Exception?>? OnFinish;

    private const int MinSegmentSize = 512 * 1024;
    private const int MaxAttempts = 6;
    private static readonly HashSet<string> CredentialHeaders = new(StringComparer.OrdinalIgnoreCase) { "Cookie", "Authorization", "Proxy-Authorization" };

    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,           // followed by hand so credentials can be dropped on cross-host hops
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.None,
        ConnectTimeout = TimeSpan.FromSeconds(20),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        MaxConnectionsPerServer = 64,
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    private readonly Configuration _config;
    private readonly CancellationTokenSource _cts = new();
    private Uri _requestUrl;
    private List<SegmentInfo> _segments = [];
    private long _singleReceived;
    private bool _single;
    private int _slots;                      // parallel connections still allowed (shrinks on 429/503)

    public SegmentedDownloader(Configuration config)
    {
        _config = config;
        _requestUrl = config.Url;
    }

    public void Start() => _ = Task.Run(Run);

    public void Stop() => _cts.Cancel();

    private async Task Run()
    {
        Exception? failure = null;
        using var progressTimer = new System.Threading.Timer(_ => ReportProgress(), null, 250, 250);
        try
        {
            var ct = _cts.Token;
            if (_config.ResumeSegments is { Count: > 0 } resume && _config.ResumeTotal > 0 && File.Exists(_config.PartPath))
            {
                _segments = resume.Select(s => s.Clone()).ToList();
                await DownloadSegments(ct);
            }
            else
            {
                ProbeResult probe;
                for (var attempt = 1; ; attempt++)
                {
                    try { probe = await Probe(ct); break; }
                    catch (Exception e) when (attempt < 3 && !ct.IsCancellationRequested
                                              && (e is HttpRequestException || e is HttpStatusError { Status: >= 500 or 429 or 408 }))
                    {
                        await Task.Delay(TimeSpan.FromSeconds(2 * attempt), ct);
                    }
                }
                OnProbe?.Invoke(probe);
                if (probe.SupportsRanges && probe.TotalBytes > 0)
                {
                    _segments = Split(probe.TotalBytes, Math.Clamp(_config.SegmentCount, 1, 16));
                    await DownloadSegments(ct);
                }
                else
                {
                    _single = true;
                    await DownloadSingle(ct);
                }
            }
        }
        catch (Exception e)
        {
            failure = e;
        }
        progressTimer.Change(Timeout.Infinite, Timeout.Infinite);
        ReportProgress();
        OnFinish?.Invoke(_cts.IsCancellationRequested ? new OperationCanceledException() : Readable(failure));
    }

    /// HttpClient reports "An error occurred while sending the request."; the useful part is the inner exception.
    private static Exception? Readable(Exception? e)
    {
        if (e is not HttpRequestException { InnerException: { } inner } outer) return e;
        while (inner.InnerException != null && inner.Message.Length == 0) inner = inner.InnerException;
        return new DownloadFailure($"{outer.Message} ({inner.Message})");
    }

    private void ReportProgress()
    {
        if (_single) { OnProgress?.Invoke(Interlocked.Read(ref _singleReceived), []); return; }
        var segs = _segments.Select(s => s.Clone()).ToList();
        if (segs.Count > 0) OnProgress?.Invoke(segs.Sum(s => s.Received), segs);
    }

    private static List<SegmentInfo> Split(long total, int count)
    {
        count = (int)Math.Max(1, Math.Min(count, total / MinSegmentSize));
        var size = total / count;
        var list = new List<SegmentInfo>();
        for (var i = 0; i < count; i++)
        {
            var start = i * size;
            var end = i == count - 1 ? total - 1 : start + size - 1;
            list.Add(new SegmentInfo { Start = start, End = end });
        }
        return list;
    }

    // MARK: - HTTP

    /// Credentials (Cookie/Authorization) only go to the host the download was requested for,
    /// never to a host reached through a redirect.
    private bool SameOrigin(Uri url) =>
        string.Equals(url.Host, _config.Url.Host, StringComparison.OrdinalIgnoreCase) && url.Scheme == _config.Url.Scheme;

    private async Task<HttpResponseMessage> Send(Uri url, string? range, CancellationToken ct)
    {
        var current = url;
        for (var hop = 0; hop < 10; hop++)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, current);
            var allowCredentials = SameOrigin(current);
            foreach (var (k, v) in _config.Headers)
            {
                if (!allowCredentials && CredentialHeaders.Contains(k)) continue;
                req.Headers.TryAddWithoutValidation(k, v);
            }
            req.Headers.TryAddWithoutValidation("Accept-Encoding", "identity");
            if (range != null) req.Headers.TryAddWithoutValidation("Range", range);
            var resp = await Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            var code = (int)resp.StatusCode;
            if (code is 301 or 302 or 303 or 307 or 308 && resp.Headers.Location is { } loc)
            {
                resp.Dispose();
                current = loc.IsAbsoluteUri ? loc : new Uri(current, loc);
                if (current.Scheme != Uri.UriSchemeHttp && current.Scheme != Uri.UriSchemeHttps)
                    throw new DownloadFailure(L.T("Redirected to an unsupported address.", "Desteklenmeyen bir adrese yönlendirildi."));
                continue;
            }
            return resp;
        }
        throw new DownloadFailure(L.T("Too many redirects.", "Çok fazla yönlendirme."));
    }

    private async Task<ProbeResult> Probe(CancellationToken ct)
    {
        using var resp = await Send(_config.Url, "bytes=0-0", ct);
        var code = (int)resp.StatusCode;
        if (code >= 400) throw new HttpStatusError(code);
        _requestUrl = resp.RequestMessage?.RequestUri ?? _config.Url;
        long total = -1;
        var ranges = false;
        if (code == 206 && resp.Content.Headers.ContentRange is { Length: { } len })
        {
            total = len;
            ranges = true;
        }
        else if (resp.Content.Headers.ContentLength is { } cl)
        {
            total = cl;
        }
        return new ProbeResult(total, ranges, FileName(resp.Content.Headers.ContentDisposition),
            resp.Content.Headers.ContentType?.MediaType, _requestUrl);
    }

    private static string? FileName(ContentDispositionHeaderValue? cd)
    {
        if (cd == null) return null;
        var name = cd.FileNameStar ?? cd.FileName;
        name = name?.Trim().Trim('"');
        return string.IsNullOrWhiteSpace(name) ? null : Path.GetFileName(name.Replace('\\', '/').Split('/').Last());
    }

    /// A connection that sends nothing for this long is dropped (and retried for segments).
    private static readonly TimeSpan StallTimeout = TimeSpan.FromSeconds(30);

    private async Task DownloadSingle(CancellationToken ct)
    {
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
        stall.CancelAfter(StallTimeout);
        try
        {
            using var resp = await Send(_requestUrl, null, stall.Token);
            var code = (int)resp.StatusCode;
            if (code >= 400) throw new HttpStatusError(code);
            Directory.CreateDirectory(Path.GetDirectoryName(_config.PartPath)!);
            await using var file = new FileStream(_config.PartPath, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16, useAsync: true);
            File.SetAttributes(_config.PartPath, FileAttributes.Hidden);
            await using var body = await resp.Content.ReadAsStreamAsync(stall.Token);
            var buffer = new byte[1 << 16];
            while (true)
            {
                stall.CancelAfter(StallTimeout);
                var n = await body.ReadAsync(buffer, stall.Token);
                if (n == 0) break;
                await file.WriteAsync(buffer.AsMemory(0, n), ct);
                Interlocked.Add(ref _singleReceived, n);
            }
            var expected = resp.Content.Headers.ContentLength;
            if (expected is > 0 && _singleReceived < expected)
                throw new DownloadFailure(L.T("The connection closed before the file was complete.", "Dosya tamamlanmadan bağlantı kapandı."));
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new DownloadFailure(L.T("The server stopped sending data.", "Sunucu veri göndermeyi bıraktı."));
        }
    }

    private async Task DownloadSegments(CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_config.PartPath)!);
        var total = _segments[^1].End + 1;
        using (var handle = File.OpenHandle(_config.PartPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read, FileOptions.Asynchronous))
        {
            if (RandomAccess.GetLength(handle) != total) RandomAccess.SetLength(handle, total);
            File.SetAttributes(_config.PartPath, FileAttributes.Hidden);
            _slots = _segments.Count;
            using var gate = new SemaphoreSlim(_segments.Count);
            var tasks = _segments.Where(s => !s.IsDone).Select(s => DownloadSegment(s, handle, gate, ct)).ToList();
            await Task.WhenAll(tasks);
        }
        if (_segments.Any(s => !s.IsDone))
            throw new DownloadFailure(L.T("Some parts could not be downloaded.", "Bazı parçalar indirilemedi."));
    }

    private async Task DownloadSegment(SegmentInfo seg, SafeFileHandle handle, SemaphoreSlim gate, CancellationToken ct)
    {
        var buffer = new byte[1 << 16];
        var attempt = 0;
        while (!seg.IsDone)
        {
            await gate.WaitAsync(ct);
            var release = true;
            TimeSpan? retryAfter = null;
            using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
            stall.CancelAfter(StallTimeout);
            try
            {
                using var resp = await Send(_requestUrl, $"bytes={seg.Start + seg.Received}-{seg.End}", stall.Token);
                var code = (int)resp.StatusCode;
                if (code is 429 or 503)
                {
                    // Too many connections for this server: give up this slot for good (keep at least one).
                    if (Interlocked.Decrement(ref _slots) >= 1) release = false;
                    else Interlocked.Increment(ref _slots);
                    throw new HttpStatusError(code);
                }
                if (code >= 400) throw new HttpStatusError(code);
                if (code != 206)
                    throw new DownloadFailure(L.T("The server stopped accepting partial requests.", "Sunucu parçalı istekleri kabul etmeyi bıraktı."));
                await using var body = await resp.Content.ReadAsStreamAsync(stall.Token);
                while (!seg.IsDone)
                {
                    stall.CancelAfter(StallTimeout);
                    var n = await body.ReadAsync(buffer, stall.Token);
                    if (n == 0) break;
                    n = (int)Math.Min(n, seg.Length - seg.Received);
                    await RandomAccess.WriteAsync(handle, buffer.AsMemory(0, n), seg.Start + seg.Received, ct);
                    seg.Received += n;
                    attempt = 0;
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException   // stalled connection
                                      || e is HttpStatusError { Status: >= 500 or 429 or 408 }
                                      || e is DownloadFailure && attempt < 1)
            {
                if (++attempt >= MaxAttempts)
                    throw e is OperationCanceledException ? new DownloadFailure(L.T("The server stopped sending data.", "Sunucu veri göndermeyi bıraktı.")) : e;
                retryAfter = TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt)));
            }
            finally
            {
                if (release) gate.Release();
            }
            // Wait outside the gate so other segments can use the connection meanwhile.
            if (retryAfter is { } wait) await Task.Delay(wait, ct);
        }
    }
}
