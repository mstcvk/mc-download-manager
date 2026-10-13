using System.Windows;
using Microsoft.Win32;

namespace MCDM;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // The browser starts this exe as its native messaging host: answer on stdin/stdout, no UI.
        if (NativeHost.IsHostInvocation(args)) return NativeHost.Serve();

        bool background = args.Contains("--background");
        using var mutex = new Mutex(true, @"Local\MCDownloadManager", out bool first);
        var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\MCDownloadManager.Show");
        if (!first)
        {
            // Already running: a normal launch brings its window forward, a background launch does nothing.
            if (!background) showSignal.Set();
            return 0;
        }
        System.Windows.Forms.Application.EnableVisualStyles();   // TaskDialog needs common controls v6
        var app = new App(showSignal, background);
        return app.Run();
    }
}

/// Shared model objects and app lifetime: the app lives in the notification area (tray); closing the window keeps it
/// running so browser extensions can hand over downloads at any time. Quit from the tray icon.
public sealed class App : Application
{
    public static AppSettings Settings => AppSettings.Shared;
    public static DownloadStore Store { get; private set; } = null!;
    public static ServerController Server { get; private set; } = null!;

    readonly EventWaitHandle showSignal;
    readonly bool background;

    public App(EventWaitHandle showSignal, bool background)
    {
        this.showSignal = showSignal;
        this.background = background;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        ThemeMode = ThemeMode.System;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/MCDownloadManager;component/UI/Styles.xaml") });
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Store = new DownloadStore(Settings);
        Server = new ServerController(Store, Settings);
        ClipboardWatcher.Start(Store, Settings);
        UpdateChecker.Shared.Start(Store, Settings);
        TrayIcon.Create(Store, Server);
        Task.Run(NativeHost.Register);
        LoginItem.RegisterByDefaultIfNeeded();
        if (Settings.OnboardingDone) Store.PrepareDownloadFolder();

        ThreadPool.RegisterWaitForSingleObject(showSignal, (_, _) => Dispatcher.BeginInvoke(ShowMainWindow), null, -1, false);

        // First launch always shows the window (onboarding).
        bool startsHidden = Settings.OnboardingDone && (background || Settings.StartInTray);
        if (!startsHidden) ShowMainWindow();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Store.Shutdown();
        TrayIcon.Dispose();
        base.OnExit(e);
    }

    public static void ShowMainWindow()
    {
        var w = Current.Windows.OfType<MainWindow>().FirstOrDefault() ?? new MainWindow();
        w.Show();
        if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
        w.Activate();
    }

    public static void ShowSettings(int tab = 0)
    {
        var w = Current.Windows.OfType<SettingsWindow>().FirstOrDefault() ?? new SettingsWindow();
        w.SelectTab(tab);
        w.Show();
        w.Activate();
    }

    public static void ShowAddDownload()
    {
        ShowMainWindow();
        var main = Current.Windows.OfType<MainWindow>().First();
        new AddDownloadWindow { Owner = main }.ShowDialog();
    }

    public static void Quit() => Current.Shutdown();
}

/// "Open at login" via HKCU\…\Run. Enabled once by default after the first-run setup.
public static class LoginItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "MC Download Manager";
    static string Command => $"\"{Environment.ProcessPath}\" --background";

    public static bool IsEnabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(ValueName) is string;
        }
    }

    public static void SetEnabled(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) k.SetValue(ValueName, Command); else k.DeleteValue(ValueName, false);
    }

    /// Registers the app as a login item the first time the setup is completed, so browser extensions find the bridge
    /// running after a reboot without the user opening the app. Only for an installed copy (Program Files or
    /// %LOCALAPPDATA%\Programs); build folders would leave stale entries.
    public static void RegisterByDefaultIfNeeded()
    {
        var s = AppSettings.Shared;
        if (!s.OnboardingDone || s.LoginItemAutoRegistered) return;
        var exe = Environment.ProcessPath ?? "";
        string[] roots =
        [
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"),
        ];
        if (!roots.Any(r => exe.StartsWith(r + "\\", StringComparison.OrdinalIgnoreCase))) return;
        s.LoginItemAutoRegistered = true;
        try { SetEnabled(true); } catch { }
    }
}
