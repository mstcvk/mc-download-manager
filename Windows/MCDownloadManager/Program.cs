namespace MCDownloadManager;

static class Program
{
    private const string MutexName = @"Local\MCDownloadManager.Instance";
    private const string ShowEventName = @"Local\MCDownloadManager.Show";

    public static bool IsAppRunning()
    {
        try
        {
            using var m = Mutex.OpenExisting(MutexName);
            return true;
        }
        catch { return false; }
    }

    [STAThread]
    static int Main(string[] args)
    {
        if (NativeHost.IsInvocation(args)) return NativeHost.Run();
        if (args.Contains("--unregister"))
        {
            NativeHostRegistry.Unregister();
            Startup.Set(false);
            return 0;
        }

        var background = args.Contains("--background");
        using var mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            // Already running: bring its window up (unless started in the background) and exit.
            if (!background)
                try { using var e = EventWaitHandle.OpenExisting(ShowEventName); e.Set(); } catch { }
            return 0;
        }

        ApplicationConfiguration.Initialize();
        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        var form = new MainForm(startHidden: background || AppSettings.Shared.StartMinimized && args.Contains("--autostart"));
        var waiter = new Thread(() =>
        {
            while (showEvent.WaitOne())
                try { form.BeginInvoke(form.ShowFromTray); } catch { return; }
        }) { IsBackground = true };
        waiter.Start();
        Application.Run(new HiddenStartContext(form));
        return 0;
    }

    /// Lets the main form start hidden in the tray instead of always showing at launch.
    private sealed class HiddenStartContext : ApplicationContext
    {
        public HiddenStartContext(MainForm form)
        {
            MainForm = form;
            form.CreateHandleAndMaybeShow();
        }
    }
}

/// Start with Windows: HKCU\…\Run entry.
static class Startup
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "MC Download Manager";

    public static bool IsEnabled
    {
        get
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(Name) is string;
        }
    }

    public static void Set(bool on)
    {
        using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Key);
        if (on && Environment.ProcessPath is { } exe) k.SetValue(Name, $"\"{exe}\" --autostart");
        else k.DeleteValue(Name, throwOnMissingValue: false);
    }
}
