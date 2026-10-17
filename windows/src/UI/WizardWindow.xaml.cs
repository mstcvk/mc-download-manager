using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace MCDM;

/// Guided, one-browser-at-a-time setup of the browser extensions (Chrome, Edge, Brave, Firefox).
public partial class WizardWindow : Window
{
    static WizardWindow? shared;

    /// Opens the wizard (or brings the open one forward) from onboarding and Settings alike.
    public static void ShowShared()
    {
        shared ??= new WizardWindow();
        shared.Show();
        shared.Activate();
    }

    readonly List<BrowserKind> browsers;
    readonly ServerController server = App.Server;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    int browserIndex, step;
    string? error;
    bool copied;
    string? tempAddon;

    WizardWindow()
    {
        InitializeComponent();
        var installed = BrowserIntegration.InstalledBrowsers;
        browsers = installed.Count > 0 ? installed : [BrowserKind.Chrome];
        timer.Tick += (_, _) => { if (IsLastStep) Render(); };   // live "connected" status
        timer.Start();
        Closed += (_, _) => { timer.Stop(); shared = null; };
        Render();
    }

    BrowserKind Browser => browsers[browserIndex];
    int StepCount => Browser == BrowserKind.Firefox ? 2 : 4;
    bool IsLastStep => step >= StepCount - 1;
    bool IsLastBrowser => browserIndex >= browsers.Count - 1;
    bool Connected => server.IsExtensionConnected(Browser.Id);

    // MARK: Navigation

    void Next_Click(object sender, RoutedEventArgs e)
    {
        error = null;
        copied = false;
        if (!IsLastStep) step++;
        else if (IsLastBrowser) { Close(); return; }
        else { browserIndex++; step = 0; }
        Render();
    }

    void Back_Click(object sender, RoutedEventArgs e)
    {
        error = null;
        if (step > 0) step--;
        else if (browserIndex > 0) { browserIndex--; step = 0; }
        Render();
    }

    void Skip_Click(object sender, RoutedEventArgs e)
    {
        error = null;
        if (IsLastBrowser) { Close(); return; }
        browserIndex++;
        step = 0;
        Render();
    }

    // MARK: Rendering

    void Render()
    {
        BrowserIcon.Source = Browser.Icon;
        BrowserName.Text = Browser.Name;
        Progress.Text = L.T("Browser %lld of %lld · Step %lld of %lld", browserIndex + 1, browsers.Count, step + 1, StepCount);
        Dots.Children.Clear();
        for (int i = 0; i < StepCount; i++)
            Dots.Children.Add(new Ellipse
            {
                Width = 8, Height = 8, Margin = new Thickness(3, 0, 3, 0),
                Fill = i <= step ? new SolidColorBrush(Color.FromRgb(0x2F, 0x6F, 0xEB)) : new SolidColorBrush(Color.FromArgb(0x50, 0x80, 0x80, 0x80)),
            });
        BackButton.IsEnabled = step > 0 || browserIndex > 0;
        SkipButton.Visibility = !IsLastBrowser || !IsLastStep ? Visibility.Visible : Visibility.Collapsed;
        NextButton.Content = IsLastStep ? (IsLastBrowser ? L.T("Finish") : L.T("Next Browser")) : L.T("Next");

        Body.Children.Clear();
        if (Browser == BrowserKind.Firefox) FirefoxStep(); else ChromiumStep();
        if (error != null) Body.Children.Add(new TextBlock { Text = error, Foreground = (Brush)FindResource("Bad"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0) });
    }

    void ChromiumStep()
    {
        var folder = BrowserIntegration.PluginFolder(Browser);
        switch (step)
        {
            case 0:
                Heading(L.T("Prepare the extension files"));
                Text(L.T("%@ does not allow apps to install extensions automatically, so the extension is loaded from a folder. The files are placed in:", Browser.Name));
                PathBox(folder);
                Buttons(
                    (L.T("Prepare Files"), () =>
                    {
                        try { BrowserIntegration.PrepareFiles(Browser); error = null; }
                        catch (Exception e) { error = e.Message; }
                        Render();
                    }, true),
                    (L.T("Show in Explorer"), () => BrowserIntegration.RevealInExplorer(folder), BrowserIntegration.FilesPrepared(Browser)));
                Status(BrowserIntegration.FilesPrepared(Browser), L.T("Files are ready"), L.T("Click “Prepare Files”"));
                Caption(L.T("Keep this folder in place; the browser loads the extension from it."));
                break;
            case 1:
                Heading(L.T("Open the extensions page and turn on Developer mode"));
                Text(Browser == BrowserKind.Edge
                    ? L.T("Click the button below. On the page that opens, switch on “Developer mode” in the left sidebar.")
                    : L.T("Click the button below. On the page that opens, switch on “Developer mode” in the top right corner."));
                Buttons((L.T("Open %@", Browser.ExtensionsPageUrl), () => BrowserIntegration.OpenExtensionsPage(Browser), true));
                break;
            case 2:
                Heading(L.T("Load the extension folder"));
                Text(L.T("Click “Load unpacked” on the extensions page. In the folder dialog, paste the path below into the address bar and press Enter, then click “Select Folder”."));
                PathBox(folder);
                Buttons(
                    (copied ? L.T("Copied") : L.T("Copy Folder Path"), () =>
                    {
                        try { Clipboard.SetText(folder); copied = true; } catch { }
                        Render();
                    }, true),
                    (L.T("Show in Explorer"), () => BrowserIntegration.RevealInExplorer(folder), true));
                break;
            default:
                Heading(L.T("%@ is ready", Browser.Name));
                Text(L.T("Pin MC Download Manager to the toolbar (puzzle icon ▸ pin). Its popup should show “Connected”. Downloads of the captured file types are now handed to the app."));
                Status(Connected, L.T("Extension has connected to the app"), L.T("Waiting for the extension to connect (it connects right after loading)"));
                break;
        }
    }

    void FirefoxStep()
    {
        if (step == 0)
        {
            if (BrowserIntegration.SignedFirefoxAddon != null)
            {
                Heading(L.T("Add the extension to Firefox"));
                Text(L.T("The Firefox add-on is included in the app and signed by Mozilla. Click the button below; Firefox opens and asks “Add MC Download Manager?”. Click “Add”."));
                Buttons((L.T("Add to Firefox"), BrowserIntegration.InstallFirefoxAddon, true));
                Caption(L.T("To capture downloads in private windows too, tick “Allow this extension to run in Private Windows” in the confirmation that follows."));
            }
            else if (BrowserIntegration.UnsignedFirefoxAddon != null)
            {
                Heading(L.T("Load the extension temporarily"));
                Text(L.T("This build contains an unsigned Firefox add-on. Firefox only loads it temporarily: it is removed when Firefox quits. On the page that opens, click “Load Temporary Add-on…” and select the file below."));
                Buttons(
                    (L.T("Open about:debugging"), () =>
                    {
                        try { tempAddon = BrowserIntegration.PrepareTemporaryFirefoxAddon(); error = null; }
                        catch (Exception e) { error = e.Message; }
                        BrowserIntegration.OpenFirefoxDebugging();
                        Render();
                    }, true),
                    (L.T("Show in Explorer"), () => { if (tempAddon != null) BrowserIntegration.RevealInExplorer(tempAddon); }, tempAddon != null));
                if (tempAddon != null) PathBox(tempAddon);
            }
            else
            {
                Heading(L.T("Firefox add-on not included"));
                Text(L.T("This build of the app does not contain the Firefox add-on. Build it with scripts/pack-firefox.ps1, or install the release version of the app."));
            }
        }
        else
        {
            Heading(L.T("Firefox is ready"));
            Text(L.T("Pin MC Download Manager to the toolbar (puzzle icon ▸ gear ▸ Pin to Toolbar). Its popup should show “Connected”. Downloads of the captured file types are now handed to the app."));
            Status(Connected, L.T("Extension has connected to the app"), L.T("Waiting for the extension to connect (it connects right after loading)"));
        }
    }

    // MARK: Pieces

    void Heading(string s) => Body.Children.Add(new TextBlock { Text = s, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) });
    void Text(string s) => Body.Children.Add(new TextBlock { Text = s, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) });
    void Caption(string s) => Body.Children.Add(new TextBlock { Text = s, Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 6, 0, 0) });
    void PathBox(string s) => Body.Children.Add(new TextBox { Text = s, Style = (Style)FindResource("PathBox"), Margin = new Thickness(0, 0, 0, 10) });

    void Buttons(params (string Label, Action Action, bool Enabled)[] buttons)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        foreach (var (label, action, enabled) in buttons)
        {
            var b = new Button { Content = label, IsEnabled = enabled, Margin = new Thickness(0, 0, 8, 0) };
            b.Click += (_, _) => action();
            row.Children.Add(b);
        }
        Body.Children.Add(row);
    }

    void Status(bool ok, string okText, string pendingText)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        row.Children.Add(new TextBlock
        {
            Style = (Style)FindResource("Glyph"), Text = ok ? "" : "", Margin = new Thickness(0, 0, 8, 0),
            Foreground = ok ? (Brush)FindResource("Ok") : Foreground,
        });
        row.Children.Add(new TextBlock { Text = ok ? okText : pendingText, Opacity = ok ? 1 : 0.7, TextWrapping = TextWrapping.Wrap });
        Body.Children.Add(row);
    }
}
