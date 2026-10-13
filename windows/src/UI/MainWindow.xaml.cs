using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;

namespace MCDM;

public sealed class SidebarEntry(string label, string glyph, Func<DownloadItem, bool> filter, bool header = false) : INotifyPropertyChanged
{
    public string Label { get; } = label;
    public string Glyph { get; } = glyph;
    public Func<DownloadItem, bool> Filter { get; } = filter;
    public Thickness Indent { get; } = header ? new Thickness(0) : new Thickness(18, 0, 0, 0);
    public FontWeight Weight { get; } = header ? FontWeights.SemiBold : FontWeights.Normal;
    public int Count { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public void Recount(IEnumerable<DownloadItem> items)
    {
        int n = items.Count(Filter);
        if (n == Count) return;
        Count = n;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Count)));
    }
}

public partial class MainWindow : Window
{
    readonly DownloadStore store = App.Store;
    readonly ServerController server = App.Server;
    readonly ICollectionView view;
    readonly List<SidebarEntry> entries;

    public MainWindow()
    {
        InitializeComponent();
        entries =
        [
            new(L.T("All"), "", _ => true, header: true),
            .. FileCategories.All.Select(c => new SidebarEntry(c.Label(), c.Glyph(), i => i.Category == c)),
            new(L.T("Finished"), "", i => i.IsFinished, header: true),
            new(L.T("Unfinished"), "", i => !i.IsFinished, header: true),
        ];
        Sidebar.ItemsSource = entries;
        Sidebar.SelectedIndex = 0;

        view = new CollectionViewSource { Source = store.Items }.View;
        view.SortDescriptions.Add(new SortDescription(nameof(DownloadItem.CreatedAt), ListSortDirection.Descending));
        view.Filter = o => o is DownloadItem i && Matches(i);
        Table.ItemsSource = view;

        store.PropertyChanged += OnStoreTick;
        store.Items.CollectionChanged += (_, _) => Refresh();
        server.PropertyChanged += OnStoreTick;
        Closed += (_, _) =>
        {
            store.PropertyChanged -= OnStoreTick;
            server.PropertyChanged -= OnStoreTick;
        };
        Drop += OnDrop;
        PreviewKeyDown += OnKeyDown;
        Loaded += (_, _) =>
        {
            if (!App.Settings.OnboardingDone) Dispatcher.BeginInvoke(() => new OnboardingWindow { Owner = this }.ShowDialog());
        };
        Refresh();
    }

    bool Matches(DownloadItem i)
    {
        if (Sidebar.SelectedItem is SidebarEntry e && !e.Filter(i)) return false;
        var q = SearchBox.Text;
        return q.Length == 0 || i.FileName.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                             || i.Url.AbsoluteUri.Contains(q, StringComparison.CurrentCultureIgnoreCase);
    }

    void OnStoreTick(object? sender, PropertyChangedEventArgs e) => UpdateStatus();

    void Refresh()
    {
        view.Refresh();
        UpdateStatus();
    }

    void UpdateStatus()
    {
        foreach (var e in entries) e.Recount(store.Items);
        bool empty = view.IsEmpty;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        EmptyTitle.Text = SearchBox.Text.Length == 0 ? L.T("No downloads in this view") : L.T("No matching downloads");
        EmptyHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        BridgeDot.Fill = (Brush)FindResource(server.Running ? "Ok" : "Bad");
        BridgeText.Text = server.Running ? L.T("Browser bridge is running") : server.StatusText;
        UnfinishedText.Text = store.UnfinishedCount.ToString();
        SpeedText.Text = Fmt.Speed(store.TotalSpeed);
    }

    List<DownloadItem> Selected => Table.SelectedItems.OfType<DownloadItem>().ToList();

    // MARK: Toolbar

    void Add_Click(object sender, RoutedEventArgs e) => new AddDownloadWindow { Owner = this }.ShowDialog();
    void StartQueue_Click(object sender, RoutedEventArgs e) => store.ResumeAll();
    void StopAll_Click(object sender, RoutedEventArgs e) => store.PauseAll();
    void ClearFinished_Click(object sender, RoutedEventArgs e) => store.ClearFinished();
    void Settings_Click(object sender, RoutedEventArgs e) => App.ShowSettings();
    void Search_Changed(object sender, TextChangedEventArgs e) => Refresh();
    void Sidebar_Changed(object sender, SelectionChangedEventArgs e) { if (view != null) Refresh(); }

    // MARK: Table

    void Grid_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && ItemsControl.ContainerFromElement(Table, d) is DataGridRow { Item: DownloadItem item })
            DetailWindows.Show(item.Id, store);
    }

    void Grid_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Delete && Selected is { Count: > 0 } sel)
        {
            foreach (var i in sel) store.Remove(i.Id);
            e.Handled = true;
        }
        else if (e.Key == Key.Enter && Selected is { Count: > 0 } open)
        {
            foreach (var i in open) DetailWindows.Show(i.Id, store);
            e.Handled = true;
        }
    }

    void Grid_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var menu = Table.ContextMenu!;
        menu.Items.Clear();
        var items = Selected;
        void Add(string text, Action action) => menu.Items.Add(MakeItem(text, action));

        if (items.Count == 0)
        {
            Add(L.T("Add URL…"), () => new AddDownloadWindow { Owner = this }.ShowDialog());
            return;
        }
        Add(L.T("Open Download Window"), () => items.ForEach(i => DetailWindows.Show(i.Id, store)));
        menu.Items.Add(new Separator());
        if (items.Any(i => i.State.IsActive() || i.State == DownloadState.Queued))
        {
            Add(L.T("Pause"), () => items.ForEach(i => store.Pause(i.Id)));
            Add(L.T("Cancel"), () => items.ForEach(i => store.Cancel(i.Id)));
        }
        if (items.Any(i => i.State is DownloadState.Paused or DownloadState.Failed or DownloadState.Cancelled))
            Add(L.T("Resume / Retry"), () => items.ForEach(i => store.Resume(i.Id)));
        if (items.Count == 1)
        {
            var item = items[0];
            menu.Items.Add(new Separator());
            Add(L.T("Copy URL"), () => { try { Clipboard.SetText(item.Url.AbsoluteUri); } catch { } });
            if (item.State == DownloadState.Completed)
            {
                Add(L.T("Open"), () => store.Open(item));
                Add(L.T("Show in Explorer"), () => store.RevealInExplorer(item));
            }
        }
        menu.Items.Add(new Separator());
        Add(L.T("Remove from List"), () => items.ForEach(i => store.Remove(i.Id)));
        if (items.Any(i => i.State == DownloadState.Completed))
            Add(L.T("Move File to Recycle Bin and Remove"), () => items.ForEach(i => store.Remove(i.Id, deleteFile: true)));
    }

    static MenuItem MakeItem(string text, Action action)
    {
        var m = new MenuItem { Header = text };
        m.Click += (_, _) => action();
        return m;
    }

    // MARK: Keyboard, paste, drop

    void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers != ModifierKeys.Control) return;
        if (e.Key == Key.N)
        {
            new AddDownloadWindow { Owner = this }.ShowDialog();
            e.Handled = true;
        }
        else if (e.Key == Key.V && Keyboard.FocusedElement is not TextBox)
        {
            try { if (Clipboard.ContainsText()) ClipboardWatcher.HandlePaste(Clipboard.GetText()); } catch { }
            e.Handled = true;
        }
        else if (e.Key == Key.F)
        {
            SearchBox.Focus();
            e.Handled = true;
        }
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        string? text = null;
        if (e.Data.GetDataPresent("UniformResourceLocatorW")) text = ReadUrlFormat(e.Data.GetData("UniformResourceLocatorW"));
        if (text == null && e.Data.GetDataPresent(DataFormats.UnicodeText)) text = e.Data.GetData(DataFormats.UnicodeText) as string;
        if (!string.IsNullOrWhiteSpace(text)) store.AddUrls(text, DownloadKind.File);
    }

    static string? ReadUrlFormat(object? data) => data switch
    {
        string s => s,
        System.IO.MemoryStream ms => System.Text.Encoding.Unicode.GetString(ms.ToArray()).TrimEnd('\0'),
        _ => null,
    };
}
