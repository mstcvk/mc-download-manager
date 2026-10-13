using System.ComponentModel;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Windows.Threading;

namespace MCDM;

/// Checks GitHub Releases for a newer version and notifies the user.
public sealed class UpdateChecker : INotifyPropertyChanged
{
    public static UpdateChecker Shared { get; } = new();

    /// GitHub repository the Windows releases are published to.
    public const string Repo = "mstcvk/mc-download-manager-windows";
    public static readonly Uri ReleasesPage = new($"https://github.com/{Repo}/releases/latest");

    public string? LatestVersion { get; private set; }
    public bool Checking { get; private set; }
    public DateTime? LastCheck { get; private set; }
    public string? LastError { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    DownloadStore? store;
    AppSettings? settings;
    DispatcherTimer? timer;

    public static string CurrentVersion => ServerController.Version;

    public void Start(DownloadStore s, AppSettings st)
    {
        store = s;
        settings = st;
        var first = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        first.Tick += (_, _) => { first.Stop(); CheckIfDue(); };
        first.Start();
        timer = new DispatcherTimer { Interval = TimeSpan.FromHours(1) };
        timer.Tick += (_, _) => CheckIfDue();
        timer.Start();
    }

    void CheckIfDue()
    {
        if (settings is not { CheckForUpdates: true }) return;
        if (settings.LastUpdateCheck is { } last && (DateTime.Now - last).TotalHours < 20) return;
        Check(interactive: false);
    }

    sealed record Release(string Version, Uri Page, Uri? Package, string Notes);

    public async void Check(bool interactive)
    {
        if (Checking) return;
        Checking = true;
        LastError = null;
        Changed();
        Release? release = null;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("MCDownloadManager/" + CurrentVersion);
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            var obj = JsonNode.Parse(await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases/latest"));
            var tag = obj?["tag_name"]?.GetValue<string>() ?? throw new Exception();
            var assets = obj["assets"] as JsonArray ?? [];
            // Prefer the installer, then the portable zip.
            var package = assets.Select(a => (Name: a?["name"]?.GetValue<string>() ?? "", Url: a?["browser_download_url"]?.GetValue<string>()))
                .Where(a => a.Url != null && (a.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)))
                .OrderBy(a => a.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                .Select(a => new Uri(a.Url!)).FirstOrDefault();
            release = new Release(tag.TrimStart('v'),
                Uri.TryCreate(obj["html_url"]?.GetValue<string>(), UriKind.Absolute, out var page) ? page : ReleasesPage,
                package, (obj["body"]?.GetValue<string>() ?? "").Trim());
        }
        catch (Exception e)
        {
            LastError = e is HttpRequestException or TaskCanceledException ? e.Message : L.T("No release information available yet.");
        }
        Checking = false;
        LastCheck = DateTime.Now;
        if (settings != null) { settings.LastUpdateCheck = LastCheck; settings.Save(); }
        LatestVersion = release?.Version ?? LatestVersion;
        Changed();

        if (release == null)
        {
            if (interactive) Dialogs.Info(L.T("Could not check for updates"), LastError ?? "", error: true);
            return;
        }
        if (IsNewer(release.Version, CurrentVersion))
        {
            if (interactive || settings?.SkippedVersion != release.Version) ShowUpdate(release);
        }
        else if (interactive)
        {
            Dialogs.Info(L.T("You're up to date"), L.T("MC Download Manager %@ is the latest version.", CurrentVersion));
        }
    }

    public static bool IsNewer(string a, string b)
    {
        static int[] Parts(string s) => s.Split('.').Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0).ToArray();
        var pa = Parts(a);
        var pb = Parts(b);
        for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            int x = i < pa.Length ? pa[i] : 0, y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    void ShowUpdate(Release r)
    {
        var info = L.T("You are using version %@.", CurrentVersion);
        if (r.Notes.Length > 0) info += "\n\n" + (r.Notes.Length > 600 ? r.Notes[..600] : r.Notes);
        var (button, _) = Dialogs.Ask(L.T("MC Download Manager %@ is available", r.Version), info,
            [r.Package != null ? L.T("Download Update") : L.T("Open Release Page"), L.T("Later"), L.T("Skip This Version")]);
        switch (button)
        {
            case 0:
                if (r.Package != null && store != null)
                    store.Add(new NewDownloadRequest(r.Package) { FileName = Path.GetFileName(r.Package.AbsolutePath) });
                else
                    Shell.Open(r.Page.AbsoluteUri);
                break;
            case 2:
                if (settings != null) settings.SkippedVersion = r.Version;
                settings?.Save();
                break;
        }
    }
}
