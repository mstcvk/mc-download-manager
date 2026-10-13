using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace MCDM;

/// In-app login window (WebView2). Cookies from the session are exported to a Netscape cookie file that yt-dlp uses,
/// so age-restricted / members-only videos can be downloaded.
public sealed class SiteLoginManager : INotifyPropertyChanged
{
    public static SiteLoginManager Shared { get; } = new();

    public int CookieCount { get; private set; }
    public DateTime? SavedAt { get; private set; }
    public List<string> Domains { get; private set; } = [];
    public event PropertyChangedEventHandler? PropertyChanged;

    public static string CookieFileFullPath => Path.Combine(AppSettings.SupportDir, "cookies", "sites.txt");
    /// Path of the shared cookie file if it exists.
    public static string? CookieFilePath => File.Exists(CookieFileFullPath) ? CookieFileFullPath : null;
    static string WebDataFolder => Path.Combine(AppSettings.SupportDir, "WebView2");

    Window? window;
    WebView2? web;
    TextBlock? status;

    SiteLoginManager() => LoadStatus();

    // MARK: Window

    public async void OpenLogin(string url = "https://accounts.google.com/ServiceLogin?continue=https://www.youtube.com/")
    {
        if (window != null)
        {
            window.Activate();
            web?.CoreWebView2?.Navigate(url);
            return;
        }
        web = new WebView2();
        status = new TextBlock { Text = L.T("Sign in to your account, then click “Save Cookies”."), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        var save = new Button { Content = L.T("Save Cookies"), IsDefault = true, MinWidth = 120, Margin = new Thickness(8, 0, 0, 0) };
        save.Click += (_, _) => SaveCookies();
        var yt = new Button { Content = "YouTube", MinWidth = 90, Margin = new Thickness(8, 0, 0, 0) };
        yt.Click += (_, _) => web.CoreWebView2?.Navigate("https://www.youtube.com/");

        var bar = new DockPanel { Margin = new Thickness(16, 12, 16, 12) };
        DockPanel.SetDock(save, Dock.Right);
        DockPanel.SetDock(yt, Dock.Right);
        bar.Children.Add(save);
        bar.Children.Add(yt);
        bar.Children.Add(status);
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(web);

        window = new Window
        {
            Title = L.T("Site Login"), Width = 980, Height = 720, Content = root,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
        };
        window.Closed += (_, _) => { web?.Dispose(); web = null; window = null; status = null; };
        window.Show();
        try
        {
            var env = await CoreWebView2Environment.CreateAsync(null, WebDataFolder);
            await web.EnsureCoreWebView2Async(env);
            web.CoreWebView2.NavigationCompleted += (_, _) =>
            {
                if (status != null && Uri.TryCreate(web?.Source?.ToString(), UriKind.Absolute, out var u))
                    status.Text = L.T("Signed-in pages: %@. Click “Save Cookies” when done.", u.Host);
            };
            web.CoreWebView2.Navigate(url);
        }
        catch (Exception e)
        {
            status.Text = L.T("The built-in browser (WebView2) is not available: %@", e.Message);
        }
    }

    // MARK: Cookies

    async void SaveCookies()
    {
        if (web?.CoreWebView2 is not { } core) return;
        var cookies = await core.CookieManager.GetCookiesAsync("");
        Write(cookies);
        LoadStatus();
        if (status != null) status.Text = L.T("Saved %lld cookies. yt-dlp will use them for video downloads.", cookies.Count);
    }

    static void Write(IEnumerable<CoreWebView2Cookie> cookies)
    {
        var lines = new List<string> { "# Netscape HTTP Cookie File", "# Exported by MC Download Manager" };
        foreach (var c in cookies)
        {
            long exp = c.IsSession ? 0 : new DateTimeOffset(c.Expires.ToUniversalTime()).ToUnixTimeSeconds();
            lines.Add(string.Join('\t', c.Domain, c.Domain.StartsWith('.') ? "TRUE" : "FALSE", c.Path, c.IsSecure ? "TRUE" : "FALSE",
                exp.ToString(), c.Name, c.Value));
        }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CookieFileFullPath)!);
            File.WriteAllText(CookieFileFullPath, string.Join("\n", lines) + "\n");
        }
        catch { }
    }

    public void Clear()
    {
        try { File.Delete(CookieFileFullPath); } catch { }
        if (web?.CoreWebView2 is { } core) core.CookieManager.DeleteAllCookies();
        else try { Directory.Delete(WebDataFolder, true); } catch { }
        LoadStatus();
    }

    void LoadStatus()
    {
        string text;
        try { text = File.ReadAllText(CookieFileFullPath); }
        catch
        {
            CookieCount = 0; SavedAt = null; Domains = [];
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
            return;
        }
        var rows = text.Split('\n').Where(r => r.Length > 0 && !r.StartsWith('#')).ToList();
        CookieCount = rows.Count;
        Domains = rows.Select(r => r.Split('\t')[0].TrimStart('.'))
            .Select(h => { var p = h.Split('.'); return p.Length >= 2 ? string.Join('.', p[^2..]) : h; })
            .Distinct().Order().ToList();
        SavedAt = File.GetLastWriteTime(CookieFileFullPath);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }
}
