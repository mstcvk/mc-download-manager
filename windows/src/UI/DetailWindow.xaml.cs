using System.ComponentModel;
using System.Windows;

namespace MCDM;

/// Per-download window (IDM style): status, segment bar and connection table. Turns into a "completed" view at the end.
public partial class DetailWindow : Window
{
    public const double FullHeight = 560, CompactHeight = 300, CompletedHeight = 270;

    readonly DownloadStore store;
    readonly Guid id;
    DownloadItem? item;
    bool showDetails = true;

    public sealed record ConnRow(int Index, string Received, string Start, string Info);

    public DetailWindow(Guid id, DownloadStore store)
    {
        this.id = id;
        this.store = store;
        InitializeComponent();
        item = store.Items.FirstOrDefault(i => i.Id == id);
        if (item != null)
        {
            item.PropertyChanged += OnItemChanged;
            Bar.Item = item;
        }
        Height = item?.State == DownloadState.Completed ? CompletedHeight : FullHeight;
        store.Items.CollectionChanged += OnListChanged;
        Closed += (_, _) =>
        {
            store.Items.CollectionChanged -= OnListChanged;
            if (item != null) item.PropertyChanged -= OnItemChanged;
        };
        Render();
    }

    void OnItemChanged(object? sender, PropertyChangedEventArgs e) => Render();

    void OnListChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (item == null || store.Items.Contains(item)) return;
        item.PropertyChanged -= OnItemChanged;
        item = null;
        Render();
    }

    void Render()
    {
        if (item is not { } it)
        {
            ActivePanel.Visibility = CompletedPanel.Visibility = Visibility.Collapsed;
            RemovedText.Visibility = Visibility.Visible;
            return;
        }
        bool done = it.State == DownloadState.Completed;
        ActivePanel.Visibility = done ? Visibility.Collapsed : Visibility.Visible;
        CompletedPanel.Visibility = done ? Visibility.Visible : Visibility.Collapsed;
        if (done) RenderCompleted(it); else RenderActive(it);
    }

    void RenderActive(DownloadItem it)
    {
        UrlText.Text = it.Url.AbsoluteUri;
        StatusText.Text = it.State switch
        {
            DownloadState.Downloading when it.Kind == DownloadKind.Video => it.Stage.Length == 0 ? L.T("Downloading with yt-dlp…") : it.Stage,
            DownloadState.Downloading => L.T("Receiving data…"),
            DownloadState.Failed => it.ErrorMessage ?? L.T("Error"),
            _ => it.State.Label(),
        };
        StatusText.Foreground = it.State == DownloadState.Failed ? (System.Windows.Media.Brush)FindResource("Bad") : Foreground;
        SizeText.Text = it.TotalBytes > 0 ? Fmt.Size(it.TotalBytes) : L.T("Unknown");
        DownloadedText.Text = it.TotalBytes > 0 ? $"{Fmt.Size(it.ReceivedBytes)}  ({(int)(it.Progress * 100)}%)" : Fmt.Size(it.ReceivedBytes);
        RateText.Text = it.State == DownloadState.Downloading ? Fmt.Speed(it.Speed) : "—";
        EtaText.Text = it.Eta is double eta ? Fmt.Duration(eta) : "—";
        ResumeText.Text = it.Kind == DownloadKind.Video ? "yt-dlp"
            : it.SupportsRanges ? L.T("Yes")
            : it.State is DownloadState.Queued or DownloadState.Probing ? "?" : L.T("No");
        SaveToText.Text = it.FinalPath ?? store.DestinationPath(it);
        Progress.Value = it.TotalBytes > 0 ? it.Progress : 0;

        DetailsButton.Content = showDetails ? L.T("<< Hide Details") : L.T("Show Details >>");
        bool running = it.State is DownloadState.Downloading or DownloadState.Probing or DownloadState.Queued;
        PrimaryButton.Content = running ? L.T("Pause") : L.T("Resume");
        PrimaryButton.IsDefault = !running;
        SecondButton.Content = running ? L.T("Cancel") : L.T("Remove from List");

        DetailsPanel.Visibility = showDetails ? Visibility.Visible : Visibility.Collapsed;
        bool video = it.Kind == DownloadKind.Video;
        Connections.Visibility = Bar.Visibility = video ? Visibility.Collapsed : Visibility.Visible;
        LogBox.Visibility = video ? Visibility.Visible : Visibility.Collapsed;
        DetailsCaption.Text = video ? L.T("yt-dlp output") : L.T("Start positions and download progress by connections");
        if (video)
        {
            var log = it.Log.Length == 0 ? L.T("Waiting…") : it.Log;
            if (LogBox.Text != log)
            {
                LogBox.Text = log;
                LogBox.ScrollToEnd();
            }
        }
        else
        {
            var rows = ConnectionRows(it);
            if (Connections.ItemsSource is not List<ConnRow> old || !old.SequenceEqual(rows)) Connections.ItemsSource = rows;
        }
    }

    static List<ConnRow> ConnectionRows(DownloadItem it)
    {
        if (it.Segments.Count == 0)
        {
            if (it.State == DownloadState.Queued) return [];
            var info = it.State switch
            {
                DownloadState.Probing => L.T("Sending GET…"),
                DownloadState.Downloading => L.T("Receiving data… (single stream)"),
                DownloadState.Paused => L.T("Paused"),
                _ => it.State.Label(),
            };
            return [new ConnRow(1, Fmt.Size(it.ReceivedBytes), Fmt.Size(0), info)];
        }
        return it.Segments.Select((s, i) => new ConnRow(i + 1, Fmt.Size(s.Received), Fmt.Size(s.Start),
            s.IsDone ? L.T("Completed")
            : it.State == DownloadState.Downloading ? (s.Received == 0 ? L.T("Sending GET…") : L.T("Receiving data…"))
            : it.State == DownloadState.Paused ? L.T("Paused")
            : it.State.Label())).ToList();
    }

    void RenderCompleted(DownloadItem it)
    {
        DoneName.Text = it.FileName;
        DoneSize.Text = Fmt.Size(it.TotalBytes);
        DoneLocation.Text = it.FinalPath != null ? Path.GetDirectoryName(it.FinalPath) : store.DestinationDirectory(it);
        DoneUrl.Text = it.Url.AbsoluteUri;
        DoneAt.Text = it.CompletedAt?.ToString("g") ?? "";
    }

    void Details_Click(object sender, RoutedEventArgs e)
    {
        showDetails = !showDetails;
        Height = showDetails ? FullHeight : CompactHeight;
        Render();
    }

    void Primary_Click(object sender, RoutedEventArgs e)
    {
        if (item == null) return;
        if (item.State is DownloadState.Downloading or DownloadState.Probing or DownloadState.Queued) store.Pause(id); else store.Resume(id);
    }

    void Second_Click(object sender, RoutedEventArgs e)
    {
        if (item == null) return;
        if (item.State is DownloadState.Downloading or DownloadState.Probing or DownloadState.Queued) store.Cancel(id);
        else { store.Remove(id); Close(); }
    }

    void Close_Click(object sender, RoutedEventArgs e) => Close();
    void Reveal_Click(object sender, RoutedEventArgs e) { if (item != null) store.RevealInExplorer(item); }
    void Open_Click(object sender, RoutedEventArgs e) { if (item != null) store.Open(item); Close(); }
}

/// Manages the per-download windows so they can be opened from anywhere (e.g. a request from the browser).
public static class DetailWindows
{
    static readonly Dictionary<Guid, DetailWindow> Windows = [];

    public static void Show(Guid id, DownloadStore store)
    {
        if (Windows.TryGetValue(id, out var existing))
        {
            if (existing.WindowState == WindowState.Minimized) existing.WindowState = WindowState.Normal;
            existing.Activate();
            return;
        }
        var w = new DetailWindow(id, store) { Title = store.Items.FirstOrDefault(i => i.Id == id)?.FileName ?? L.T("Download") };
        if (Windows.Values.LastOrDefault() is { } last)
        {
            w.WindowStartupLocation = WindowStartupLocation.Manual;
            w.Left = last.Left + 24;
            w.Top = last.Top + 24;
        }
        else
        {
            w.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
        Windows[id] = w;
        w.Closed += (_, _) => Windows.Remove(id);
        // Browser hand-offs arrive while another app is in front: show on top once, then behave normally.
        w.Topmost = true;
        w.Show();
        w.Activate();
        w.Topmost = false;
    }

    public static void Close(Guid id)
    {
        if (Windows.TryGetValue(id, out var w)) w.Close();
    }

    /// When a download finishes: close automatically or shrink to the "completed" size.
    public static void DidComplete(Guid id, bool autoClose)
    {
        if (!Windows.TryGetValue(id, out var w)) return;
        if (autoClose) w.Close(); else w.Height = DetailWindow.CompletedHeight;
    }

    /// Titles follow the progress ("24% · file.zip").
    public static void RefreshTitles(IEnumerable<DownloadItem> items)
    {
        foreach (var (id, w) in Windows)
        {
            if (items.FirstOrDefault(i => i.Id == id) is not { } item) continue;
            var title = (item.TotalBytes > 0 && item.State != DownloadState.Completed ? $"{(int)(item.Progress * 100)}% · " : "") + item.FileName;
            if (w.Title != title) w.Title = title;
        }
    }
}
