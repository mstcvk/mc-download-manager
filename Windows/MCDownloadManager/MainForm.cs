using System.Diagnostics;

namespace MCDownloadManager;

public sealed class MainForm : Form
{
    private readonly AppSettings _settings = AppSettings.Shared;
    private readonly DownloadStore _store;
    private readonly BridgeController _bridge;
    private readonly bool _startHidden;
    private bool _exiting;

    private readonly ListView _list = new();
    private readonly ListBox _filters = new();
    private readonly ToolStripTextBox _search = new();
    private readonly ToolStripStatusLabel _serverLabel = new();
    private readonly ToolStripStatusLabel _extensionLabel = new();
    private readonly ToolStripStatusLabel _countLabel = new() { Spring = true, TextAlign = ContentAlignment.MiddleRight };
    private readonly NotifyIcon _tray = new();
    private readonly System.Windows.Forms.Timer _refresh = new() { Interval = 400 };
    private readonly Dictionary<Guid, ListViewItem> _rows = new();
    private bool _dirty = true;

    private sealed record Filter(string Label, Func<DownloadItem, bool> Match)
    {
        public override string ToString() => Label;
    }

    public static Icon AppIcon { get; } = LoadIcon();

    private static Icon LoadIcon()
    {
        using var s = typeof(MainForm).Assembly.GetManifestResourceStream("icon128.png");
        if (s == null) return SystemIcons.Application;
        using var bmp = new Bitmap(s);
        return Icon.FromHandle(bmp.GetHicon());
    }

    public MainForm(bool startHidden)
    {
        _startHidden = startHidden;
        Text = "MC Download Manager";
        Icon = AppIcon;
        Size = new Size(1100, 620);
        MinimumSize = new Size(720, 400);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);

        var ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _store = new DownloadStore(_settings, ui);
        _bridge = new BridgeController(_store, _settings, ui);

        BuildToolbar();
        BuildList();
        BuildFilters();
        BuildStatusBar();
        BuildTray();

        _store.Changed += () => _dirty = true;
        _store.Completed += OnCompleted;
        _bridge.StatusChanged += UpdateStatus;
        _refresh.Tick += (_, _) => { if (_dirty) RefreshList(); UpdateStatus(); };
        _refresh.Start();

        NativeHostRegistry.Register();
        _bridge.Start();
    }

    public void CreateHandleAndMaybeShow()
    {
        if (_startHidden) { _ = Handle; return; }
        Show();
    }

    public void ShowFromTray()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
    }

    // MARK: - Layout

    private void BuildToolbar()
    {
        var bar = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, Padding = new Padding(6, 2, 6, 2), ImageScalingSize = new Size(20, 20) };
        ToolStripButton B(string text, Action a, string? tip = null)
        {
            var b = new ToolStripButton(text) { ToolTipText = tip ?? text };
            b.Click += (_, _) => a();
            bar.Items.Add(b);
            return b;
        }
        B(L.T("➕ Add URL", "➕ Adres ekle"), () => ShowAddDialog(DownloadKind.File));
        B(L.T("🎬 Add video", "🎬 Video ekle"), () => ShowAddDialog(DownloadKind.Video), L.T("Download a page's video with yt-dlp", "Sayfadaki videoyu yt-dlp ile indir"));
        bar.Items.Add(new ToolStripSeparator());
        B(L.T("▶ Resume", "▶ Sürdür"), () => ForSelected(i => _store.Resume(i.Id)));
        B(L.T("⏸ Pause", "⏸ Duraklat"), () => ForSelected(i => _store.Pause(i.Id)));
        B(L.T("✕ Cancel", "✕ İptal"), () => ForSelected(i => _store.Cancel(i.Id)));
        B(L.T("🗑 Remove", "🗑 Kaldır"), RemoveSelected);
        bar.Items.Add(new ToolStripSeparator());
        B(L.T("📂 Folder", "📂 Klasör"), () => { if (Selected().FirstOrDefault() is { } i) _store.Reveal(i); else OpenDownloadFolder(); });
        var more = new ToolStripDropDownButton(L.T("All…", "Tümü…"));
        more.DropDownItems.Add(L.T("Resume all", "Tümünü sürdür"), null, (_, _) => _store.ResumeAll());
        more.DropDownItems.Add(L.T("Pause all", "Tümünü duraklat"), null, (_, _) => _store.PauseAll());
        more.DropDownItems.Add(L.T("Clear finished", "Bitenleri temizle"), null, (_, _) => _store.ClearFinished());
        bar.Items.Add(more);

        var right = new ToolStripButton(L.T("⚙ Settings", "⚙ Ayarlar")) { Alignment = ToolStripItemAlignment.Right };
        right.Click += (_, _) => ShowSettings();
        var ext = new ToolStripButton(L.T("🧩 Browser extension", "🧩 Tarayıcı eklentisi")) { Alignment = ToolStripItemAlignment.Right };
        ext.Click += (_, _) => new ExtensionSetupForm(_bridge).ShowDialog(this);
        _search.Alignment = ToolStripItemAlignment.Right;
        _search.TextBox.PlaceholderText = L.T("Search", "Ara");
        _search.Size = new Size(160, 23);
        _search.TextChanged += (_, _) => { _dirty = true; RefreshList(); };
        bar.Items.Add(right);
        bar.Items.Add(ext);
        bar.Items.Add(_search);
        Controls.Add(bar);
    }

    private void BuildFilters()
    {
        _filters.Dock = DockStyle.Left;
        _filters.Width = 150;
        _filters.BorderStyle = BorderStyle.None;
        _filters.IntegralHeight = false;
        _filters.ItemHeight = 26;
        _filters.DrawMode = DrawMode.OwnerDrawFixed;
        _filters.DrawItem += (_, e) =>
        {
            if (e.Index < 0) return;
            e.DrawBackground();
            var f = (Filter)_filters.Items[e.Index];
            var n = _store.Items.Count(f.Match);
            var r = e.Bounds; r.Inflate(-8, 0);
            TextRenderer.DrawText(e.Graphics, f.Label, Font, r, e.ForeColor, TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
            if (n > 0) TextRenderer.DrawText(e.Graphics, n.ToString(), Font, r, (e.State & DrawItemState.Selected) != 0 ? e.ForeColor : SystemColors.GrayText, TextFormatFlags.VerticalCenter | TextFormatFlags.Right);
        };
        _filters.Items.Add(new Filter(L.T("All downloads", "Tüm indirmeler"), _ => true));
        _filters.Items.Add(new Filter(L.T("Active", "Etkin"), i => i.State.IsActive() || i.State == DownloadState.Queued));
        _filters.Items.Add(new Filter(L.T("Completed", "Tamamlanan"), i => i.State == DownloadState.Completed));
        _filters.Items.Add(new Filter(L.T("Unfinished", "Bitmemiş"), i => i.State is DownloadState.Paused or DownloadState.Failed or DownloadState.Cancelled));
        foreach (var c in Enum.GetValues<FileCategory>())
            _filters.Items.Add(new Filter("   " + c.Label(), i => i.Category == c));
        _filters.SelectedIndex = 0;
        _filters.SelectedIndexChanged += (_, _) => { _dirty = true; RefreshList(); };
        Controls.Add(_filters);
        _filters.BringToFront();
        _list.BringToFront();
    }

    private void BuildList()
    {
        _list.Dock = DockStyle.Fill;
        _list.View = View.Details;
        _list.FullRowSelect = true;
        _list.HideSelection = false;
        _list.BorderStyle = BorderStyle.None;
        _list.OwnerDraw = true;
        _list.SmallImageList = new ImageList { ImageSize = new Size(1, 24) };   // taller rows for the progress bar
        _list.Columns.Add(L.T("Name", "Ad"), 320);
        _list.Columns.Add(L.T("Size", "Boyut"), 90, HorizontalAlignment.Right);
        _list.Columns.Add(L.T("Progress", "İlerleme"), 130);
        _list.Columns.Add(L.T("Speed", "Hız"), 80, HorizontalAlignment.Right);
        _list.Columns.Add(L.T("Time left", "Kalan"), 60, HorizontalAlignment.Right);
        _list.Columns.Add(L.T("Added", "Eklenme"), 115);
        _list.Columns.Add(L.T("Status", "Durum"), 230);
        // The name column takes the remaining width, so there is no horizontal scroll bar.
        _list.ClientSizeChanged += (_, _) =>
        {
            var others = _list.Columns.Cast<ColumnHeader>().Skip(1).Sum(c => c.Width);
            _list.Columns[0].Width = Math.Max(160, _list.ClientSize.Width - others - 1);
        };
        _list.DrawColumnHeader += (_, e) => e.DrawDefault = true;
        _list.DrawSubItem += DrawSubItem;
        _list.DoubleClick += (_, _) =>
        {
            if (Selected().FirstOrDefault() is not { } i) return;
            if (i.State == DownloadState.Completed) _store.Open(i); else ShowDetails(i);
        };
        _list.KeyDown += (_, e) => { if (e.KeyCode == Keys.Delete) RemoveSelected(); };

        var menu = new ContextMenuStrip();
        menu.Opening += (_, e) =>
        {
            menu.Items.Clear();
            var sel = Selected();
            if (sel.Count == 0) { e.Cancel = true; return; }
            var one = sel[0];
            if (sel.Count == 1 && one.State == DownloadState.Completed)
                menu.Items.Add(L.T("Open", "Aç"), null, (_, _) => _store.Open(one));
            menu.Items.Add(L.T("Show in folder", "Klasörde göster"), null, (_, _) => _store.Reveal(one));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(L.T("Resume", "Sürdür"), null, (_, _) => ForSelected(i => _store.Resume(i.Id)));
            menu.Items.Add(L.T("Pause", "Duraklat"), null, (_, _) => ForSelected(i => _store.Pause(i.Id)));
            menu.Items.Add(L.T("Cancel", "İptal"), null, (_, _) => ForSelected(i => _store.Cancel(i.Id)));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(L.T("Copy address", "Adresi kopyala"), null, (_, _) => Clipboard.SetText(string.Join(Environment.NewLine, sel.Select(i => i.Url))));
            if (sel.Count == 1) menu.Items.Add(L.T("Details / log…", "Ayrıntılar / günlük…"), null, (_, _) => ShowDetails(one));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(L.T("Remove from list", "Listeden kaldır"), null, (_, _) => ForSelected(i => _store.Remove(i.Id)));
            if (sel.Any(i => i.State == DownloadState.Completed))
                menu.Items.Add(L.T("Remove and move file to Recycle Bin", "Kaldır ve dosyayı Geri Dönüşüm Kutusu'na taşı"), null,
                    (_, _) => ForSelected(i => _store.Remove(i.Id, deleteFile: true)));
        };
        _list.ContextMenuStrip = menu;
        Controls.Add(_list);
    }

    private void DrawSubItem(object? sender, DrawListViewSubItemEventArgs e)
    {
        if (e.ColumnIndex != 2 || e.Item?.Tag is not DownloadItem item)
        {
            e.DrawDefault = true;
            return;
        }
        e.DrawBackground();
        if (e.Item.Selected) e.Graphics.FillRectangle(SystemBrushes.Highlight, e.Bounds);
        var r = Rectangle.Inflate(e.Bounds, -6, -4);
        using var track = new SolidBrush(Color.FromArgb(225, 228, 232));
        e.Graphics.FillRectangle(track, r);
        var color = item.State switch
        {
            DownloadState.Completed => Color.FromArgb(46, 189, 89),
            DownloadState.Failed => Color.FromArgb(215, 58, 73),
            DownloadState.Paused or DownloadState.Cancelled => Color.FromArgb(150, 150, 150),
            _ => Color.FromArgb(47, 111, 235),
        };
        var p = item.State == DownloadState.Completed ? 1 : item.Progress;
        using var fill = new SolidBrush(color);
        e.Graphics.FillRectangle(fill, r with { Width = (int)(r.Width * p) });
        var text = item.TotalBytes > 0 || item.State == DownloadState.Completed ? $"{p * 100:0}%" : "";
        TextRenderer.DrawText(e.Graphics, text, Font, r, p > 0.5 ? Color.White : Color.Black, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }

    private void BuildStatusBar()
    {
        var bar = new StatusStrip { SizingGrip = true };
        bar.Items.Add(_serverLabel);
        bar.Items.Add(new ToolStripSeparator());
        bar.Items.Add(_extensionLabel);
        bar.Items.Add(_countLabel);
        Controls.Add(bar);
    }

    private void BuildTray()
    {
        _tray.Icon = AppIcon;
        _tray.Text = "MC Download Manager";
        _tray.Visible = true;
        var menu = new ContextMenuStrip();
        menu.Items.Add(L.T("Open MC Download Manager", "MC Download Manager'ı aç"), null, (_, _) => ShowFromTray());
        menu.Items.Add(L.T("Add URL…", "Adres ekle…"), null, (_, _) => { ShowFromTray(); ShowAddDialog(DownloadKind.File); });
        menu.Items.Add(L.T("Open downloads folder", "İndirme klasörünü aç"), null, (_, _) => OpenDownloadFolder());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L.T("Pause all", "Tümünü duraklat"), null, (_, _) => _store.PauseAll());
        menu.Items.Add(L.T("Resume all", "Tümünü sürdür"), null, (_, _) => _store.ResumeAll());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L.T("Quit", "Çıkış"), null, (_, _) => ExitApp());
        _tray.ContextMenuStrip = menu;
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowFromTray(); };
        _tray.BalloonTipClicked += (_, _) => ShowFromTray();
    }

    // MARK: - Refresh

    private IEnumerable<DownloadItem> VisibleItems()
    {
        var f = _filters.SelectedItem as Filter;
        var q = _search.Text.Trim();
        return _store.Items.Where(i => (f == null || f.Match(i))
            && (q.Length == 0 || i.FileName.Contains(q, StringComparison.CurrentCultureIgnoreCase) || i.Url.Contains(q, StringComparison.OrdinalIgnoreCase)));
    }

    private void RefreshList()
    {
        _dirty = false;
        var visible = VisibleItems().ToList();
        var ids = visible.Select(i => i.Id).ToHashSet();
        _list.BeginUpdate();
        foreach (var (id, row) in _rows.Where(kv => !ids.Contains(kv.Key)).ToList())
        {
            _list.Items.Remove(row);
            _rows.Remove(id);
        }
        for (var index = 0; index < visible.Count; index++)
        {
            var item = visible[index];
            if (!_rows.TryGetValue(item.Id, out var row))
            {
                row = new ListViewItem(new string[7]);
                _rows[item.Id] = row;
                _list.Items.Insert(Math.Min(index, _list.Items.Count), row);
            }
            row.Tag = item;
            Set(row, 0, (item.Kind == DownloadKind.Video ? "🎬 " : "") + item.FileName);
            Set(row, 1, item.TotalBytes > 0 ? Fmt.Size(item.TotalBytes) : item.ReceivedBytes > 0 ? Fmt.Size(item.ReceivedBytes) : "");
            Set(row, 2, $"{item.Progress:0.000}");
            Set(row, 3, item.State == DownloadState.Downloading ? Fmt.Speed(item.Speed) : "");
            Set(row, 4, item.State == DownloadState.Downloading ? Fmt.Eta(item) : "");
            var status = item.State switch
            {
                DownloadState.Failed => $"{item.State.Label()}: {item.ErrorMessage}",
                DownloadState.Downloading when item.Stage.Length > 0 => item.Stage,
                _ => item.State.Label(),
            };
            Set(row, 5, item.CreatedAt.ToString("g"));
            Set(row, 6, status);
        }
        _list.EndUpdate();
        _filters.Invalidate();
    }

    private static void Set(ListViewItem row, int i, string text)
    {
        if (row.SubItems[i].Text != text) row.SubItems[i].Text = text;
    }

    private void UpdateStatus()
    {
        _serverLabel.Text = (_bridge.Running ? "● " : "○ ") + _bridge.StatusText;
        _serverLabel.ForeColor = _bridge.Running ? Color.FromArgb(30, 140, 60) : Color.FromArgb(200, 50, 50);
        var connected = _bridge.ExtensionConnections.Where(kv => DateTime.Now - kv.Value < TimeSpan.FromMinutes(2)).Select(kv => kv.Key).ToList();
        _extensionLabel.Text = connected.Count > 0
            ? L.T("Extension connected: ", "Eklenti bağlı: ") + string.Join(", ", connected)
            : L.T("No browser extension connected yet", "Henüz bağlı tarayıcı eklentisi yok");
        var active = _store.ActiveCount;
        var speed = _store.Items.Where(i => i.State == DownloadState.Downloading).Sum(i => i.Speed);
        _countLabel.Text = active > 0 ? L.T($"{active} active · {Fmt.Speed(speed)}", $"{active} etkin · {Fmt.Speed(speed)}") : "";
        var tip = active > 0 ? $"MC Download Manager — {active} ↓ {Fmt.Speed(speed)}" : "MC Download Manager";
        _tray.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    // MARK: - Actions

    private List<DownloadItem> Selected() =>
        _list.SelectedItems.Cast<ListViewItem>().Select(r => r.Tag).OfType<DownloadItem>().ToList();

    private void ForSelected(Action<DownloadItem> a)
    {
        foreach (var i in Selected()) a(i);
        RefreshList();
    }

    private void RemoveSelected()
    {
        var sel = Selected();
        if (sel.Count == 0) return;
        if (sel.Any(i => i.State != DownloadState.Completed) &&
            MessageBox.Show(this, L.T("Remove the selected downloads from the list? Unfinished parts are deleted.", "Seçili indirmeler listeden kaldırılsın mı? Bitmemiş parçalar silinir."),
                Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
            return;
        ForSelected(i => _store.Remove(i.Id));
    }

    private void OpenDownloadFolder()
    {
        Directory.CreateDirectory(_settings.DownloadDirectory);
        Process.Start("explorer.exe", [_settings.DownloadDirectory]);
    }

    private void ShowAddDialog(DownloadKind kind)
    {
        using var f = new AddDownloadForm(kind);
        if (f.ShowDialog(this) == DialogResult.OK) _store.AddUrls(f.Urls, f.Kind);
    }

    private void ShowSettings()
    {
        var oldPort = _settings.ClampedPort;
        using var f = new SettingsForm(_settings);
        if (f.ShowDialog(this) != DialogResult.OK) return;
        _settings.Save();
        if (_settings.ClampedPort != oldPort) _bridge.Start();
        _store.PumpQueue();
        _dirty = true;
    }

    private void ShowDetails(DownloadItem item) => new DetailsForm(item).Show(this);

    private void OnCompleted(DownloadItem item)
    {
        if (!_settings.NotifyOnComplete) return;
        _tray.ShowBalloonTip(4000, L.T("Download complete", "İndirme tamamlandı"), item.FileName, ToolTipIcon.Info);
    }

    private void ExitApp()
    {
        _exiting = true;
        Close();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_exiting && e.CloseReason == CloseReason.UserClosing)
        {
            // Closing the window keeps the app in the tray so the browser extension can still hand over downloads.
            e.Cancel = true;
            Hide();
            return;
        }
        _refresh.Stop();
        _bridge.Dispose();
        _store.Shutdown();
        _tray.Visible = false;
        _tray.Dispose();
        base.OnFormClosing(e);
    }
}
