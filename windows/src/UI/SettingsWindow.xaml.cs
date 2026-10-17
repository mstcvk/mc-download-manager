using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace MCDM;

public partial class SettingsWindow : Window
{
    readonly AppSettings settings = App.Settings;
    readonly ServerController server = App.Server;
    readonly ToolInstaller installer = ToolInstaller.Shared;
    readonly SiteLoginManager login = SiteLoginManager.Shared;
    readonly UpdateChecker updater = UpdateChecker.Shared;
    readonly DispatcherTimer refreshTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    public sealed record BrowserRow(string Name, ImageSource? Icon, string Status, Brush StatusBrush);

    static readonly (string Tag, string Label)[] Containers =
    [
        ("mp4", "MP4 (H.264/AAC, plays everywhere)"), ("mkv", "MKV"), ("webm", "WebM"), ("original", "Original (no conversion)"),
    ];
    static readonly (int Tag, string Label)[] Heights =
    [
        (0, "Best available"), (2160, "2160p (4K)"), (1440, "1440p"), (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p"),
        (-1, "Audio only (M4A)"), (-2, "Audio only (MP3)"),
    ];

    public SettingsWindow()
    {
        InitializeComponent();
        DataContext = settings;
        LoginIntro.Text = L.T("Some videos require a signed-in account. Sign in once in the built-in browser window; the saved cookies are passed to yt-dlp for video downloads. Downloads started from the browser extension already carry the browser's cookies.");

        for (int i = 1; i <= 10; i++) ConcurrentBox.Items.Add(i);
        ConcurrentBox.SelectedItem = Math.Clamp(settings.MaxConcurrent, 1, 10);
        foreach (var (_, label) in Containers) ContainerBox.Items.Add(L.T(label));
        ContainerBox.SelectedIndex = Math.Max(0, Array.FindIndex(Containers, c => c.Tag == settings.VideoContainer));
        foreach (var (_, label) in Heights) HeightBox.Items.Add(L.T(label));
        HeightBox.SelectedIndex = Math.Max(0, Array.FindIndex(Heights, h => h.Tag == settings.VideoMaxHeight));
        PortBox.Text = settings.ServerPort.ToString();
        LoginBox.IsChecked = LoginItem.IsEnabled;
        PluginRootText.Text = BrowserIntegration.PluginsRoot;

        PropertyChangedEventHandler refresh = (_, _) => Dispatcher.BeginInvoke(RefreshAll);
        server.PropertyChanged += refresh;
        installer.PropertyChanged += refresh;
        login.PropertyChanged += refresh;
        updater.PropertyChanged += refresh;
        settings.PropertyChanged += refresh;
        // Keep the browser status live: the wizard and the extensions change it while this window is open.
        refreshTimer.Tick += (_, _) => RefreshBrowsers();
        refreshTimer.Start();
        Activated += (_, _) => RefreshBrowsers();
        Closed += (_, _) =>
        {
            refreshTimer.Stop();
            server.PropertyChanged -= refresh;
            installer.PropertyChanged -= refresh;
            login.PropertyChanged -= refresh;
            updater.PropertyChanged -= refresh;
            settings.PropertyChanged -= refresh;
        };
        installer.RefreshVersion(settings.YtdlpPath);
        RefreshAll();
    }

    public void SelectTab(int index) => Tabs.SelectedIndex = index;

    void RefreshAll()
    {
        SegmentsLabel.Text = L.T("Connections per download: %lld", settings.SegmentCount);
        ConcurrentLabel.Text = L.T("Concurrent downloads");

        CurrentVersionText.Text = L.T("Current version: %@", UpdateChecker.CurrentVersion);
        LatestVersionText.Text = updater.LatestVersion is { } v ? L.T("Latest release: %@", v) : "";
        LastCheckText.Text = updater.LastCheck is { } d ? L.T("Last checked: %@", d.ToString("g")) : "";
        UpdateErrorText.Text = updater.LastError ?? "";
        CheckNowButton.Content = updater.Checking ? L.T("Checking…") : L.T("Check Now");
        CheckNowButton.IsEnabled = !updater.Checking;

        BridgeDot.Fill = (Brush)FindResource(server.Running ? "Ok" : "Bad");
        BridgeText.Text = server.StatusText;
        RefreshBrowsers();

        if (login.CookieCount > 0)
        {
            LoginText.Text = L.T("Signed in: %@", string.Join(", ", login.Domains.Take(4)));
            LoginDetail.Text = login.SavedAt is { } at ? L.T("%lld cookies saved %@", login.CookieCount, at.ToString("g")) : "";
        }
        else
        {
            LoginText.Text = L.T("Not signed in");
            LoginDetail.Text = "";
        }
        ClearLoginButton.IsEnabled = login.CookieCount > 0;

        var ytdlp = VideoDownloader.LocateYtDlp(settings.YtdlpPath);
        YtDlpText.Text = ytdlp == null ? L.T("yt-dlp not found") : installer.InstalledVersion is { } yv ? L.T("yt-dlp %@", yv) : "yt-dlp";
        YtDlpText.Foreground = ytdlp == null ? (Brush)FindResource("Bad") : Foreground;
        YtDlpPathText.Text = ytdlp ?? "";
        YtDlpButton.Content = installer.Busy ? L.T("Installing…") : ytdlp == null ? L.T("Install yt-dlp") : L.T("Update yt-dlp");
        YtDlpButton.IsEnabled = DenoButton.IsEnabled = !installer.Busy;
        InstallProgress.Visibility = installer.Busy ? Visibility.Visible : Visibility.Collapsed;
        InstallProgress.Value = installer.Progress;
        InstallMessage.Text = installer.Message ?? "";

        var deno = VideoDownloader.LocateDeno();
        DenoText.Text = deno == null ? L.T("deno not installed (needed for YouTube)") : installer.DenoVersion ?? "deno";
        DenoText.Foreground = deno == null ? (Brush)FindResource("Warn") : Foreground;
        DenoPathText.Text = deno ?? "";
        DenoButton.Content = deno == null ? L.T("Install deno") : L.T("Update deno");

        var ff = VideoDownloader.LocateFfmpeg();
        FfmpegText.Text = ff != null ? L.T("ffmpeg: %@", ff) : L.T("ffmpeg not found (merging video and audio will not work)");
        FfmpegText.Foreground = ff != null ? Foreground : (Brush)FindResource("Bad");

        EffectiveArgs.Text = L.T("Effective arguments: %@", string.Join(" ", settings.YtdlpFormatArguments));
    }

    void RefreshBrowsers()
    {
        BrowserList.ItemsSource = BrowserIntegration.InstalledBrowsers.Select(b =>
        {
            if (server.IsExtensionConnected(b.Id, 3600)) return new BrowserRow(b.Name, b.Icon, "✓ " + L.T("Connected"), (Brush)FindResource("Ok"));
            if (b.IsChromium && BrowserIntegration.FilesPrepared(b)) return new BrowserRow(b.Name, b.Icon, L.T("Files prepared, not loaded yet"), Foreground);
            return new BrowserRow(b.Name, b.Icon, L.T("Not installed"), Foreground);
        }).ToList();
    }

    // MARK: General

    void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { InitialDirectory = settings.DownloadDirectory };
        if (dlg.ShowDialog(this) == true) settings.DownloadDirectory = dlg.FolderName;
    }

    void ShowFolder_Click(object sender, RoutedEventArgs e)
    {
        try { Directory.CreateDirectory(settings.DownloadDirectory); } catch { }
        Shell.Open(settings.DownloadDirectory);
    }

    void Slider_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (SegmentsLabel != null) SegmentsLabel.Text = L.T("Connections per download: %lld", (int)e.NewValue);
    }

    void Concurrent_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (ConcurrentBox.SelectedItem is int n) settings.MaxConcurrent = n;
    }

    void Login_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            LoginItem.SetEnabled(LoginBox.IsChecked == true);
            LoginError.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            LoginError.Text = ex.Message;
            LoginError.Visibility = Visibility.Visible;
            LoginBox.IsChecked = LoginItem.IsEnabled;
        }
    }

    void CheckNow_Click(object sender, RoutedEventArgs e) => updater.Check(interactive: true);

    // MARK: Browser

    void Wizard_Click(object sender, RoutedEventArgs e) => WizardWindow.ShowShared();
    void Refresh_Click(object sender, RoutedEventArgs e) => RefreshBrowsers();
    void PluginFolder_Click(object sender, RoutedEventArgs e) => BrowserIntegration.RevealInExplorer(BrowserIntegration.PluginsRoot);

    void Port_LostFocus(object sender, RoutedEventArgs e) => ApplyPort();
    void Port_KeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) ApplyPort(); }

    void ApplyPort()
    {
        if (int.TryParse(PortBox.Text, out var p) && p is >= 1024 and <= 65535) settings.ServerPort = p;
        else PortBox.Text = settings.ServerPort.ToString();
    }

    // MARK: Video

    void Login_Open_Click(object sender, RoutedEventArgs e) => login.OpenLogin();
    void ClearLogin_Click(object sender, RoutedEventArgs e) => login.Clear();

    void YtDlp_Click(object sender, RoutedEventArgs e) =>
        installer.InstallOrUpdateYtDlp(_ => installer.RefreshVersion(settings.YtdlpPath));

    void Deno_Click(object sender, RoutedEventArgs e) =>
        installer.InstallDeno(_ => installer.RefreshVersion(settings.YtdlpPath));

    void ChooseYtDlp_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Filter = "yt-dlp|*.exe" };
        if (dlg.ShowDialog(this) == true) settings.YtdlpPath = dlg.FileName;
    }

    void Format_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (ContainerBox.SelectedIndex >= 0) settings.VideoContainer = Containers[ContainerBox.SelectedIndex].Tag;
        if (HeightBox.SelectedIndex >= 0) settings.VideoMaxHeight = Heights[HeightBox.SelectedIndex].Tag;
    }

    void FormatText_Changed(object sender, TextChangedEventArgs e)
    {
        if (EffectiveArgs != null) EffectiveArgs.Text = L.T("Effective arguments: %@", string.Join(" ", settings.YtdlpFormatArguments));
    }
}
