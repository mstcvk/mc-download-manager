using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace MCDM;

public sealed record ProbeResult(long TotalBytes, bool SupportsRanges, string? SuggestedFileName, string? ContentType, Uri? FinalUrl);

/// Downloads one file with N parallel HTTP Range requests (falls back to a single stream).
/// A scheduler loop owns the segment queue; segment tasks only write their bytes. Callbacks run on a worker thread.
public sealed partial class SegmentedDownloader(SegmentedDownloader.Configuration config)
{
    public sealed class Configuration
    {
        public required Uri Url { get; init; }
        public required Dictionary<string, string> Headers { get; init; }
        public required string PartPath { get; init; }
        public required int SegmentCount { get; init; }
        public long MinSegmentSize { get; init; } = 512 * 1024;
        public List<SegmentInfo> ResumeSegments { get; set; } = [];
        public long ResumeTotal { get; set; } = -1;
    }

    public Action<ProbeResult>? OnProbe;
    public Action<long, List<SegmentInfo>>? OnProgress;
    /// null = success. Not called after Stop().
    public Action<Exception?>? OnFinish;

    static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,      // followed manually so credentials never reach another host
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.None,
        MaxConnectionsPerServer = 32,
        ConnectTimeout = TimeSpan.FromSeconds(30),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    }) { Timeout = Timeout.InfiniteTimeSpan };

    static readonly TimeSpan IdleTimeout = TimeSpan.FromSeconds(30);
    const int MaxAttempts = 12;
    static readonly HashSet<string> CredentialHeaders = new(StringComparer.OrdinalIgnoreCase) { "Cookie", "Authorization", "Proxy-Authorization" };

    readonly CancellationTokenSource cts = new();
    readonly object gate = new();
    Uri requestUrl = config.Url;
    List<SegmentInfo> segments = [];
    bool single;
    long singleReceived;
    SafeFileHandle? file;
    long lastReport;
    volatile bool stopped;

    // MARK: - Control

    public void Start() => _ = Task.Run(RunAsync);

    /// Pause or cancel. The last segment state is reported through OnProgress.
    public void Stop()
    {
        stopped = true;
        cts.Cancel();
    }

    async Task RunAsync()
    {
        Exception? error = null;
        try
        {
            bool canResume = config.ResumeTotal > 0 && config.ResumeSegments.Count > 0 && File.Exists(config.PartPath);
            if (canResume)
            {
                segments = config.ResumeSegments.Select(s => s.Clone()).ToList();
                OpenFile(create: false, preallocate: null);
                if (!await RunMultiAsync()) await FallbackToSingleAsync();
            }
            else
            {
                await ProbeAndRunAsync();
            }
        }
        catch (Exception e) when (!stopped) { error = e; }
        catch { }
        finally
        {
            file?.Dispose();
            file = null;
        }
        OnProgress?.Invoke(CurrentReceived(), Snapshot());
        if (!stopped) OnFinish?.Invoke(error);
    }

    // MARK: - Helpers

    long CurrentReceived()
    {
        lock (gate) return single ? singleReceived : segments.Sum(s => s.Received);
    }

    List<SegmentInfo> Snapshot()
    {
        lock (gate) return single ? [] : segments.Select(s => s.Clone()).ToList();
    }

    void ReportProgress()
    {
        long now = Environment.TickCount64;
        long last = Interlocked.Read(ref lastReport);
        if (now - last < 200 || Interlocked.CompareExchange(ref lastReport, now, last) != last) return;
        OnProgress?.Invoke(CurrentReceived(), Snapshot());
    }

    /// Credentials (Cookie/Authorization) are only sent to the host the download was requested for,
    /// never to a host reached through a redirect.
    bool SameOrigin(Uri url) =>
        string.Equals(url.Host, config.Url.Host, StringComparison.OrdinalIgnoreCase)
        && string.Equals(url.Scheme, config.Url.Scheme, StringComparison.OrdinalIgnoreCase);

    async Task<(HttpResponseMessage Response, Uri FinalUrl)> SendAsync(string? range, CancellationToken ct)
    {
        var url = requestUrl;
        for (int hop = 0; ; hop++)
        {
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            bool allowCredentials = SameOrigin(url);
            foreach (var (k, v) in config.Headers)
            {
                if (k.Equals("Accept-Encoding", StringComparison.OrdinalIgnoreCase) || k.Equals("Range", StringComparison.OrdinalIgnoreCase)) continue;
                if (allowCredentials || !CredentialHeaders.Contains(k)) req.Headers.TryAddWithoutValidation(k, v);
            }
            req.Headers.TryAddWithoutValidation("Accept-Encoding", "identity");
            if (range != null) req.Headers.TryAddWithoutValidation("Range", range);
            req.Headers.CacheControl = new() { NoCache = true };

            var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            int status = (int)resp.StatusCode;
            if (status is 301 or 302 or 303 or 307 or 308 && resp.Headers.Location is { } loc && hop < 10)
            {
                resp.Dispose();
                url = loc.IsAbsoluteUri ? loc : new Uri(url, loc);
                continue;
            }
            return (resp, url);
        }
    }

    async Task ProbeAndRunAsync()
    {
        long total = -1;
        bool ranges = false;
        using (var idle = CancellationTokenSource.CreateLinkedTokenSource(cts.Token))
        {
            idle.CancelAfter(IdleTimeout);
            var (resp, finalUrl) = await WithTimeout(() => SendAsync("bytes=0-0", idle.Token));
            using (resp)
            {
                int status = (int)resp.StatusCode;
                if (status is < 200 or > 299) throw new HttpStatusError(status);

                if (status == 206 && resp.Content.Headers.ContentRange?.Length is long t)
                {
                    total = t;
                    ranges = true;
                }
                else
                {
                    total = resp.Content.Headers.ContentLength ?? -1;
                    ranges = total > 0 && resp.Headers.AcceptRanges.Any(r => r.Contains("bytes", StringComparison.OrdinalIgnoreCase));
                }
                requestUrl = finalUrl;

                string? disposition = resp.Content.Headers.TryGetValues("Content-Disposition", out var cd) ? string.Join(", ", cd) : null;
                var name = FileNameFromContentDisposition(disposition);
                var ctype = resp.Content.Headers.ContentType?.MediaType;
                OnProbe?.Invoke(new ProbeResult(total, ranges, name, ctype, finalUrl));
            }
        }

        int count = ranges ? (int)Math.Max(1, Math.Min(config.SegmentCount, total / config.MinSegmentSize)) : 1;
        if (ranges && count > 1)
        {
            segments = MakeSegments(total, count);
            OpenFile(create: true, preallocate: total);
            if (await RunMultiAsync()) return;
            await FallbackToSingleAsync();
            return;
        }
        OpenFile(create: true, preallocate: null);
        await RunSingleAsync();
    }

    public static List<SegmentInfo> MakeSegments(long total, int count)
    {
        long size = total / count;
        return Enumerable.Range(0, count).Select(i =>
        {
            long start = i * size;
            return new SegmentInfo { Start = start, End = i == count - 1 ? total - 1 : start + size - 1 };
        }).ToList();
    }

    void OpenFile(bool create, long? preallocate)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(config.PartPath)!);
            file?.Dispose();
            file = File.OpenHandle(config.PartPath, create ? FileMode.Create : FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read | FileShare.Delete);
            if (preallocate is long size && size > 0) RandomAccess.SetLength(file, size);
            if (create) File.SetAttributes(config.PartPath, File.GetAttributes(config.PartPath) | FileAttributes.Hidden);
        }
        catch (Exception e)
        {
            throw new DownloadFailure(L.T("Could not create file: %@", config.PartPath) + " (" + e.Message + ")");
        }
    }

    void Write(byte[] buffer, int count, long offset)
    {
        try { RandomAccess.Write(file!, buffer.AsSpan(0, count), offset); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new DownloadFailure(e.Message); }
    }

    /// Turns an idle-timeout cancellation into a TimeoutException (a Stop() cancellation passes through).
    async Task<T> WithTimeout<T>(Func<Task<T>> body)
    {
        try { return await body(); }
        catch (OperationCanceledException) when (!cts.IsCancellationRequested) { throw new TimeoutException(L.T("The request timed out.")); }
    }

    // MARK: - Multi-connection

    enum Outcome { Done, Retry, Throttle, Fallback }
    sealed record SegResult(int Index, Outcome Outcome, Exception? Error = null, int Status = 0, bool GotResponse = false);

    /// Returns false when the server ignored Range (200) and the caller should switch to a single stream.
    async Task<bool> RunMultiAsync()
    {
        var pending = Enumerable.Range(0, segments.Count).Where(i => !segments[i].IsDone).ToList();
        int activeLimit = Math.Max(1, config.SegmentCount);   // open connections (lowered on 429/503)
        var retries = new Dictionary<int, int>();
        var throttledUntil = DateTime.MinValue;
        using var multi = CancellationTokenSource.CreateLinkedTokenSource(cts.Token);
        var running = new Dictionary<Task<SegResult>, int>();
        try
        {
            while (true)
            {
                cts.Token.ThrowIfCancellationRequested();
                var wait = throttledUntil - DateTime.UtcNow;
                if (wait <= TimeSpan.Zero)
                {
                    while (running.Count < activeLimit && pending.Count > 0)
                    {
                        int i = pending[0];
                        pending.RemoveAt(0);
                        if (segments[i].IsDone) continue;
                        running[RunSegmentAsync(i, multi.Token)] = i;
                    }
                }
                if (running.Count == 0)
                {
                    if (pending.Count == 0) return true;
                    await Task.Delay(wait + TimeSpan.FromMilliseconds(50), cts.Token);
                    continue;
                }

                Task finished = wait > TimeSpan.Zero && pending.Count > 0
                    ? await Task.WhenAny(running.Keys.Cast<Task>().Append(Task.Delay(wait + TimeSpan.FromMilliseconds(50), cts.Token)))
                    : await Task.WhenAny(running.Keys);
                if (finished is not Task<SegResult> done) continue;
                running.Remove(done);
                var r = await done;   // throws for fatal errors (HTTP 4xx, disk)
                int idx = r.Index;
                switch (r.Outcome)
                {
                    case Outcome.Done:
                        activeLimit = Math.Min(config.SegmentCount, activeLimit + 1);
                        break;
                    case Outcome.Fallback:
                        return false;
                    case Outcome.Throttle:
                    {
                        // Server throttling (429/503): fewer connections, put the segment back at the front.
                        activeLimit = Math.Max(1, Math.Min(activeLimit, running.Count) - 1);
                        int attempt = retries[idx] = retries.GetValueOrDefault(idx) + 1;
                        if (attempt > MaxAttempts) throw new HttpStatusError(r.Status);
                        throttledUntil = DateTime.UtcNow.AddSeconds(Math.Min(15, 1.5 * attempt));
                        if (!pending.Contains(idx)) pending.Insert(0, idx);
                        break;
                    }
                    case Outcome.Retry:
                    {
                        if (r.GotResponse) retries[idx] = 0;
                        int attempt = retries[idx] = retries.GetValueOrDefault(idx) + 1;
                        if (attempt > MaxAttempts) throw r.Error ?? new DownloadFailure(L.T("Segment %lld could not be completed", idx + 1));
                        var until = DateTime.UtcNow.AddSeconds(Math.Min(10, attempt));
                        if (until > throttledUntil) throttledUntil = until;
                        if (!pending.Contains(idx)) pending.Add(idx);
                        break;
                    }
                }
            }
        }
        finally
        {
            multi.Cancel();
            try { await Task.WhenAll(running.Keys); } catch { }
        }
    }

    async Task<SegResult> RunSegmentAsync(int i, CancellationToken ct)
    {
        var seg = segments[i];
        bool gotResponse = false;
        try
        {
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct);
            idle.CancelAfter(IdleTimeout);
            long from;
            lock (gate) from = seg.Start + seg.Received;
            var (resp, _) = await SendAsync($"bytes={from}-{seg.End}", idle.Token);
            using (resp)
            {
                int status = (int)resp.StatusCode;
                switch (status)
                {
                    case 206: break;
                    case 200: return new(i, Outcome.Fallback);
                    case 408 or 425 or 429 or 500 or 502 or 503 or 504: return new(i, Outcome.Throttle, Status: status);
                    default: throw new HttpStatusError(status);
                }
                gotResponse = true;
                await using var stream = await resp.Content.ReadAsStreamAsync(idle.Token);
                var buffer = new byte[81920];
                while (true)
                {
                    long remaining;
                    lock (gate) remaining = seg.Length - seg.Received;
                    if (remaining <= 0) break;
                    idle.CancelAfter(IdleTimeout);
                    int n = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), idle.Token);
                    if (n == 0) break;
                    long offset;
                    lock (gate) offset = seg.Start + seg.Received;
                    Write(buffer, n, offset);
                    lock (gate) seg.Received += n;
                    ReportProgress();
                }
                return new(i, seg.IsDone ? Outcome.Done : Outcome.Retry, GotResponse: true);
            }
        }
        catch (Exception e) when (e is not DownloadFailure and not HttpStatusError)
        {
            var err = e is OperationCanceledException && !ct.IsCancellationRequested ? new TimeoutException(L.T("The request timed out.")) : e;
            return new(i, Outcome.Retry, err, GotResponse: gotResponse);
        }
    }

    // MARK: - Single stream

    /// The server ignored Range and answered 200: start over with one connection.
    async Task FallbackToSingleAsync()
    {
        OpenFile(create: true, preallocate: null);
        await RunSingleAsync();
    }

    async Task RunSingleAsync()
    {
        lock (gate)
        {
            single = true;
            singleReceived = 0;
            segments = [];
        }
        using var idle = CancellationTokenSource.CreateLinkedTokenSource(cts.Token);
        idle.CancelAfter(IdleTimeout);
        await WithTimeout(async () =>
        {
            var (resp, _) = await SendAsync(null, idle.Token);
            using (resp)
            {
                int status = (int)resp.StatusCode;
                if (status is < 200 or > 299) throw new HttpStatusError(status);
                // The real GET may differ from the probe (dynamic responses); trust its Content-Length.
                long total = resp.Content.Headers.ContentLength ?? -1;
                await using var stream = await resp.Content.ReadAsStreamAsync(idle.Token);
                var buffer = new byte[81920];
                while (true)
                {
                    idle.CancelAfter(IdleTimeout);
                    int n = await stream.ReadAsync(buffer, idle.Token);
                    if (n == 0) break;
                    Write(buffer, n, singleReceived);
                    lock (gate) singleReceived += n;
                    ReportProgress();
                }
                if (total > 0 && singleReceived < total)
                    throw new DownloadFailure(L.T("Connection closed early (%lld/%lld bytes)", singleReceived, total));
            }
            return true;
        });
    }

    // MARK: - Content-Disposition

    public static string? FileNameFromContentDisposition(string? header)
    {
        if (string.IsNullOrEmpty(header)) return null;
        // RFC 5987: filename*=UTF-8''file%20name.zip
        var m = ExtendedName().Match(header);
        if (m.Success)
        {
            var q = m.Value.IndexOf("''", StringComparison.Ordinal);
            if (q >= 0)
            {
                var enc = m.Value[(q + 2)..].Trim();
                try
                {
                    var d = Uri.UnescapeDataString(enc).Trim('"');
                    if (d.Length > 0) return d;
                }
                catch { }
            }
        }
        m = QuotedName().Match(header);
        if (m.Success)
        {
            var v = m.Groups[1].Value;
            return v.Length == 0 ? null : v;
        }
        m = PlainName().Match(header);
        if (m.Success)
        {
            var v = m.Groups[1].Value.Trim();
            return v.Length == 0 ? null : v;
        }
        return null;
    }

    [GeneratedRegex(@"filename\*\s*=\s*[^']*'[^']*'[^;]+", RegexOptions.IgnoreCase)]
    private static partial Regex ExtendedName();
    [GeneratedRegex("filename\\s*=\\s*\"([^\"]*)\"", RegexOptions.IgnoreCase)]
    private static partial Regex QuotedName();
    [GeneratedRegex(@"filename\s*=\s*([^;]+)", RegexOptions.IgnoreCase)]
    private static partial Regex PlainName();
}
