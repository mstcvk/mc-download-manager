using System.ComponentModel;
using System.Windows;
using WinForms = System.Windows.Forms;

namespace MCDM;

/// Notification-area icon (the counterpart of the macOS menu bar item) and completion notifications.
public static class TrayIcon
{
    static WinForms.NotifyIcon? icon;
    static Guid? lastNotified;

    public static void Create(DownloadStore store, ServerController server)
    {
        var stream = Application.GetResourceStream(new Uri("pack://application:,,,/MCDownloadManager;component/Resources/app.ico")).Stream;
        var menu = new WinForms.ContextMenuStrip();
        icon = new WinForms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(stream, WinForms.SystemInformation.SmallIconSize),
            Text = "MC Download Manager",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.MouseClick += (_, e) => { if (e.Button == WinForms.MouseButtons.Left) App.ShowMainWindow(); };
        icon.BalloonTipClicked += (_, _) =>
        {
            if (lastNotified is { } id) DetailWindows.Show(id, store);
        };

        var status = new WinForms.ToolStripMenuItem { Enabled = false };
        var bridge = new WinForms.ToolStripMenuItem { Enabled = false };
        menu.Items.Add(status);
        menu.Items.Add(bridge);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(L.T("Show Window"), null, (_, _) => App.ShowMainWindow());
        menu.Items.Add(L.T("New Download…"), null, (_, _) => App.ShowAddDownload());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(L.T("Pause All"), null, (_, _) => store.PauseAll());
        menu.Items.Add(L.T("Resume All"), null, (_, _) => store.ResumeAll());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(L.T("Settings…"), null, (_, _) => App.ShowSettings());
        menu.Items.Add(L.T("Check for Updates…"), null, (_, _) => UpdateChecker.Shared.Check(interactive: true));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(L.T("Quit MC Download Manager"), null, (_, _) => App.Quit());
        menu.Opening += (_, _) =>
        {
            status.Text = store.ActiveCount > 0
                ? L.T("%lld downloading · %@", store.ActiveCount, Fmt.Speed(store.TotalSpeed))
                : L.T("No active downloads");
            bridge.Text = server.Running ? L.T("Bridge is running") : L.T("Bridge is not running");
        };

        store.PropertyChanged += UpdateTooltip;
    }

    static void UpdateTooltip(object? sender, PropertyChangedEventArgs e)
    {
        if (icon == null || sender is not DownloadStore store) return;
        var text = "MC Download Manager";
        if (store.ActiveCount > 0)
        {
            text += $"\n{L.T("%lld downloading · %@", store.ActiveCount, Fmt.Speed(store.TotalSpeed))}";
            if (store.OverallProgress is double p) text += $" · {(int)(p * 100)}%";
        }
        if (text.Length > 127) text = text[..127];
        if (icon.Text != text) icon.Text = text;
    }

    public static void Notify(string title, string body, Guid id)
    {
        if (icon == null) return;
        lastNotified = id;
        icon.ShowBalloonTip(5000, title, body, WinForms.ToolTipIcon.Info);
    }

    public static void Dispose()
    {
        if (icon == null) return;
        icon.Visible = false;
        icon.Dispose();
        icon = null;
    }
}
