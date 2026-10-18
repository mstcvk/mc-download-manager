using System.Diagnostics;

namespace MCDownloadManager;

static class Ui
{
    public static TableLayoutPanel Grid(int columns) => new()
    {
        Dock = DockStyle.Fill,
        ColumnCount = columns,
        AutoSize = true,
        Padding = new Padding(12),
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
    };

    public static Label Label(string text, bool bold = false) => new()
    {
        Text = text,
        AutoSize = true,
        Anchor = AnchorStyles.Left,
        Margin = new Padding(3, 8, 3, 3),
        Font = bold ? new Font("Segoe UI", 9.5f, FontStyle.Bold) : null,
    };

    public static FlowLayoutPanel Buttons(Form form, string okText, bool cancel = true)
    {
        var p = new FlowLayoutPanel { Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Padding = new Padding(8) };
        var ok = new Button { Text = okText, DialogResult = DialogResult.OK, AutoSize = true, MinimumSize = new Size(90, 28) };
        p.Controls.Add(ok);
        form.AcceptButton = ok;
        if (cancel)
        {
            var c = new Button { Text = L.T("Cancel", "Vazgeç"), DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(90, 28) };
            p.Controls.Add(c);
            form.CancelButton = c;
        }
        return p;
    }

    public static void Setup(Form f, string title, Size size)
    {
        f.Text = title;
        f.Icon = MainForm.AppIcon;
        f.Font = new Font("Segoe UI", 9f);
        f.StartPosition = FormStartPosition.CenterParent;
        f.ClientSize = size;
        f.MinimizeBox = false;
        f.MaximizeBox = false;
        f.ShowInTaskbar = false;
        f.FormBorderStyle = FormBorderStyle.FixedDialog;
    }
}

public sealed class AddDownloadForm : Form
{
    private readonly TextBox _urls = new() { Multiline = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, AcceptsReturn = true };
    private readonly CheckBox _video = new() { AutoSize = true, Text = L.T("Video page — download with yt-dlp (YouTube, Vimeo, X, Instagram…)", "Video sayfası — yt-dlp ile indir (YouTube, Vimeo, X, Instagram…)") };

    public string Urls => _urls.Text;
    public DownloadKind Kind => _video.Checked ? DownloadKind.Video : DownloadKind.File;

    public AddDownloadForm(DownloadKind kind)
    {
        Ui.Setup(this, L.T("Add download", "İndirme ekle"), new Size(560, 260));
        _video.Checked = kind == DownloadKind.Video;
        var grid = Ui.Grid(1);
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.AutoSize = false;
        grid.Controls.Add(Ui.Label(L.T("Addresses (one per line):", "Adresler (her satıra bir tane):")));
        grid.Controls.Add(_urls);
        grid.Controls.Add(_video);
        Controls.Add(grid);
        Controls.Add(Ui.Buttons(this, L.T("Download", "İndir")));
        try
        {
            var clip = Clipboard.ContainsText() ? Clipboard.GetText().Trim() : "";
            if (clip.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || clip.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                _urls.Text = clip;
        }
        catch { }
        Shown += (_, _) => { _urls.Focus(); _urls.SelectAll(); };
    }
}

public sealed class SettingsForm : Form
{
    private readonly AppSettings _s;

    public SettingsForm(AppSettings s)
    {
        _s = s;
        Ui.Setup(this, L.T("Settings", "Ayarlar"), new Size(620, 560));
        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(General());
        tabs.TabPages.Add(CapturePage());
        tabs.TabPages.Add(Video());
        Controls.Add(tabs);
        Controls.Add(Ui.Buttons(this, L.T("Save", "Kaydet")));
    }

    private TabPage General()
    {
        var page = new TabPage(L.T("General", "Genel"));
        var g = Ui.Grid(3);
        g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        g.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        var dir = new TextBox { Text = _s.DownloadDirectory, Dock = DockStyle.Fill };
        var browse = new Button { Text = "…", Width = 32 };
        browse.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { SelectedPath = dir.Text, UseDescriptionForTitle = true, Description = L.T("Download folder", "İndirme klasörü") };
            if (d.ShowDialog(this) == DialogResult.OK) dir.Text = d.SelectedPath;
        };
        g.Controls.Add(Ui.Label(L.T("Download folder", "İndirme klasörü")));
        g.Controls.Add(dir);
        g.Controls.Add(browse);

        var organize = new CheckBox { Text = L.T("Sort into category subfolders (Video, Archives, …)", "Kategori alt klasörlerine ayır (Video, Arşivler, …)"), Checked = _s.OrganizeByCategory, AutoSize = true };
        g.Controls.Add(new Label()); g.Controls.Add(organize); g.Controls.Add(new Label());

        var segments = new NumericUpDown { Minimum = 1, Maximum = 16, Value = Math.Clamp(_s.SegmentCount, 1, 16), Width = 70 };
        g.Controls.Add(Ui.Label(L.T("Connections per file", "Dosya başına bağlantı")));
        g.Controls.Add(segments); g.Controls.Add(new Label());

        var concurrent = new NumericUpDown { Minimum = 1, Maximum = 10, Value = Math.Clamp(_s.MaxConcurrent, 1, 10), Width = 70 };
        g.Controls.Add(Ui.Label(L.T("Simultaneous downloads", "Aynı anda indirme")));
        g.Controls.Add(concurrent); g.Controls.Add(new Label());

        var port = new NumericUpDown { Minimum = 1024, Maximum = 65535, Value = _s.ClampedPort, Width = 90 };
        g.Controls.Add(Ui.Label(L.T("Extension port", "Eklenti portu")));
        g.Controls.Add(port); g.Controls.Add(new Label());

        var autoStart = new CheckBox { Text = L.T("Start downloads immediately", "İndirmeleri hemen başlat"), Checked = _s.AutoStart, AutoSize = true };
        var notify = new CheckBox { Text = L.T("Notify when a download completes", "İndirme bitince bildir"), Checked = _s.NotifyOnComplete, AutoSize = true };
        var startup = new CheckBox { Text = L.T("Start with Windows (in the tray)", "Windows ile başlat (tepside)"), Checked = Startup.IsEnabled, AutoSize = true };
        foreach (var c in new[] { autoStart, notify, startup }) { g.Controls.Add(new Label()); g.Controls.Add(c); g.Controls.Add(new Label()); }

        page.Controls.Add(g);
        FormClosing += (_, _) =>
        {
            if (DialogResult != DialogResult.OK) return;
            _s.DownloadDirectory = string.IsNullOrWhiteSpace(dir.Text) ? AppSettings.DefaultDownloadDirectory : dir.Text.Trim();
            _s.OrganizeByCategory = organize.Checked;
            _s.SegmentCount = (int)segments.Value;
            _s.MaxConcurrent = (int)concurrent.Value;
            _s.ServerPort = (int)port.Value;
            _s.AutoStart = autoStart.Checked;
            _s.NotifyOnComplete = notify.Checked;
            try { Startup.Set(startup.Checked); } catch { }
        };
        return page;
    }

    private TabPage CapturePage()
    {
        var page = new TabPage(L.T("Captured file types", "Yakalanan dosya türleri"));
        var g = Ui.Grid(1);
        g.Controls.Add(Ui.Label(L.T("Browser downloads of these types are sent to the app:", "Bu türlerdeki tarayıcı indirmeleri uygulamaya gönderilir:")));
        var boxes = new List<(CheckBox Box, string Id)>();
        foreach (var group in CaptureTypes.Groups)
        {
            var cb = new CheckBox
            {
                Text = $"{group.Category.Label()}  ({string.Join(", ", group.Extensions.Take(8))}{(group.Extensions.Length > 8 ? ", …" : "")})",
                Checked = _s.CaptureGroupIds.Contains(group.Id),
                AutoSize = true,
            };
            boxes.Add((cb, group.Id));
            g.Controls.Add(cb);
        }
        g.Controls.Add(Ui.Label(L.T("Additional extensions (comma separated):", "Ek uzantılar (virgülle ayırın):")));
        var custom = new TextBox { Text = _s.CustomExtensions, Width = 400 };
        g.Controls.Add(custom);
        page.Controls.Add(g);
        FormClosing += (_, _) =>
        {
            if (DialogResult != DialogResult.OK) return;
            _s.CaptureGroupIds = boxes.Where(b => b.Box.Checked).Select(b => b.Id).ToList();
            _s.CustomExtensions = custom.Text.Trim();
        };
        return page;
    }

    private TabPage Video()
    {
        var page = new TabPage(L.T("Video (yt-dlp)", "Video (yt-dlp)"));
        var g = Ui.Grid(3);
        g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        g.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        var quality = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
        var qualities = new (int Value, string Label)[]
        {
            (0, L.T("Best available", "En iyi")), (2160, "2160p (4K)"), (1440, "1440p"), (1080, "1080p"), (720, "720p"), (480, "480p"),
            (-1, L.T("Audio only (M4A)", "Yalnızca ses (M4A)")), (-2, L.T("Audio only (MP3)", "Yalnızca ses (MP3)")),
        };
        foreach (var q in qualities) quality.Items.Add(q.Label);
        quality.SelectedIndex = Math.Max(0, Array.FindIndex(qualities, q => q.Value == _s.VideoMaxHeight));
        g.Controls.Add(Ui.Label(L.T("Quality", "Kalite"))); g.Controls.Add(quality); g.Controls.Add(new Label());

        var container = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
        string[] containers = ["mp4", "mkv", "webm", "original"];
        container.Items.AddRange(["MP4 (H.264)", "MKV", "WebM", L.T("Original", "Orijinal")]);
        container.SelectedIndex = Math.Max(0, Array.IndexOf(containers, _s.VideoContainer));
        g.Controls.Add(Ui.Label(L.T("Container", "Kapsayıcı"))); g.Controls.Add(container); g.Controls.Add(new Label());

        var format = new TextBox { Text = _s.VideoFormat, Dock = DockStyle.Fill, PlaceholderText = L.T("optional, e.g. bv*+ba/b", "isteğe bağlı, örn. bv*+ba/b") };
        g.Controls.Add(Ui.Label(L.T("Custom -f format", "Özel -f biçimi"))); g.Controls.Add(format); g.Controls.Add(new Label());

        var path = new TextBox { Text = _s.YtdlpPath, Dock = DockStyle.Fill, PlaceholderText = L.T("automatic", "otomatik") };
        var browse = new Button { Text = "…", Width = 32 };
        browse.Click += (_, _) =>
        {
            using var d = new OpenFileDialog { Filter = "yt-dlp.exe|yt-dlp*.exe|*.exe|*.exe" };
            if (d.ShowDialog(this) == DialogResult.OK) path.Text = d.FileName;
        };
        g.Controls.Add(Ui.Label(L.T("yt-dlp path", "yt-dlp yolu"))); g.Controls.Add(path); g.Controls.Add(browse);

        var status = new Label { AutoSize = true, MaximumSize = new Size(560, 0), Margin = new Padding(3, 10, 3, 3) };
        void UpdateToolStatus()
        {
            var y = VideoDownloader.LocateYtDlp(path.Text);
            var f = VideoDownloader.LocateFfmpeg();
            var d = VideoDownloader.LocateDeno();
            status.Text = string.Join(Environment.NewLine,
                "yt-dlp: " + (y ?? L.T("not found", "bulunamadı")),
                "ffmpeg: " + (f ?? L.T("not found — needed to merge video and audio (winget install yt-dlp.FFmpeg)", "bulunamadı — video ve sesi birleştirmek için gerekli (winget install yt-dlp.FFmpeg)")),
                "deno: " + (d ?? L.T("not found — recommended for YouTube (winget install DenoLand.Deno)", "bulunamadı — YouTube için önerilir (winget install DenoLand.Deno)")));
        }
        UpdateToolStatus();
        g.SetColumnSpan(status, 3);
        g.Controls.Add(status);

        var install = new Button { Text = L.T("Install / update yt-dlp", "yt-dlp'yi kur / güncelle"), AutoSize = true };
        install.Click += async (_, _) =>
        {
            install.Enabled = false;
            var old = install.Text;
            try
            {
                var progress = new Progress<double>(p => install.Text = $"{p * 100:0}%");
                var v = await ToolInstaller.InstallYtDlp(progress);
                MessageBox.Show(this, L.T($"yt-dlp {v} installed (checksum verified).", $"yt-dlp {v} kuruldu (sağlama toplamı doğrulandı)."), Text);
            }
            catch (Exception e)
            {
                MessageBox.Show(this, e.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            install.Text = old;
            install.Enabled = true;
            UpdateToolStatus();
        };
        g.SetColumnSpan(install, 3);
        g.Controls.Add(install);

        page.Controls.Add(g);
        FormClosing += (_, _) =>
        {
            if (DialogResult != DialogResult.OK) return;
            _s.VideoMaxHeight = qualities[Math.Max(0, quality.SelectedIndex)].Value;
            _s.VideoContainer = containers[Math.Max(0, container.SelectedIndex)];
            _s.VideoFormat = format.Text.Trim();
            _s.YtdlpPath = path.Text.Trim();
        };
        return page;
    }
}

/// Copies the bundled extension to a stable folder and walks through "Load unpacked".
public sealed class ExtensionSetupForm : Form
{
    public ExtensionSetupForm(BridgeController bridge)
    {
        Ui.Setup(this, L.T("Browser extension", "Tarayıcı eklentisi"), new Size(620, 400));
        var g = Ui.Grid(1);
        g.Controls.Add(Ui.Label(L.T("Install the extension in Chrome, Edge or Brave", "Eklentiyi Chrome, Edge veya Brave'e kurun"), bold: true));
        var steps = new Label
        {
            AutoSize = true,
            MaximumSize = new Size(580, 0),
            Text = L.T(
                "1. Click “Prepare extension folder” below. The folder path is copied to the clipboard.\n" +
                "2. Open the browser's extensions page (buttons below) and turn on “Developer mode”.\n" +
                "3. Click “Load unpacked” and paste the folder path (Ctrl+V).\n" +
                "4. The extension connects to the app on its own; the status bar shows “Extension connected”.\n\n" +
                "Once connected, the browser can also start the app when a download arrives while it is closed.",
                "1. Aşağıdaki “Eklenti klasörünü hazırla” düğmesine tıklayın. Klasör yolu panoya kopyalanır.\n" +
                "2. Tarayıcının eklentiler sayfasını açın (aşağıdaki düğmeler) ve “Geliştirici modu”nu açın.\n" +
                "3. “Paketlenmemiş öğe yükle”ye tıklayıp klasör yolunu yapıştırın (Ctrl+V).\n" +
                "4. Eklenti uygulamaya kendiliğinden bağlanır; durum çubuğunda “Eklenti bağlı” yazar.\n\n" +
                "Bağlandıktan sonra uygulama kapalıyken gelen indirmelerde tarayıcı uygulamayı kendisi başlatabilir."),
        };
        g.Controls.Add(steps);

        var pathBox = new TextBox { ReadOnly = true, Width = 580, Text = NativeHostRegistry.ExtensionFolder };
        var prepare = new Button { Text = L.T("Prepare extension folder", "Eklenti klasörünü hazırla"), AutoSize = true };
        prepare.Click += (_, _) =>
        {
            try
            {
                PrepareFolder();
                Clipboard.SetText(NativeHostRegistry.ExtensionFolder);
                prepare.Text = L.T("✓ Ready — path copied", "✓ Hazır — yol kopyalandı");
            }
            catch (Exception e)
            {
                MessageBox.Show(this, e.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        };
        g.Controls.Add(prepare);
        g.Controls.Add(pathBox);

        var browsers = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 10, 0, 0) };
        AddBrowser(browsers, "Chrome", @"Google\Chrome\Application\chrome.exe", "chrome://extensions");
        AddBrowser(browsers, "Edge", @"Microsoft\Edge\Application\msedge.exe", "edge://extensions");
        AddBrowser(browsers, "Brave", @"BraveSoftware\Brave-Browser\Application\brave.exe", "brave://extensions");
        g.Controls.Add(browsers);

        var connected = bridge.ExtensionConnections.Keys.ToList();
        g.Controls.Add(Ui.Label(connected.Count > 0
            ? L.T("Connected so far: ", "Şu ana kadar bağlanan: ") + string.Join(", ", connected)
            : L.T("No extension has connected yet.", "Henüz bağlanan eklenti yok.")));
        Controls.Add(g);
        Controls.Add(Ui.Buttons(this, L.T("Close", "Kapat"), cancel: false));
    }

    private static void PrepareFolder()
    {
        var source = Path.Combine(AppContext.BaseDirectory, "Extension");
        if (!File.Exists(Path.Combine(source, "manifest.json")))
            throw new DownloadFailure(L.T("The extension files were not found next to the app.", "Eklenti dosyaları uygulamanın yanında bulunamadı."));
        var dest = NativeHostRegistry.ExtensionFolder;
        Directory.CreateDirectory(dest);
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(dest, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: true);
        }
        NativeHostRegistry.Register();
    }

    private static void AddBrowser(FlowLayoutPanel panel, string name, string relative, string page)
    {
        string? exe = null;
        foreach (var root in new[]
                 {
                     Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                     Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                     Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                 })
        {
            var p = Path.Combine(root, relative);
            if (File.Exists(p)) { exe = p; break; }
        }
        if (exe == null) return;
        var b = new Button { Text = L.T($"Open {name} extensions", $"{name} eklentilerini aç"), AutoSize = true };
        b.Click += (_, _) => { try { Process.Start(exe, [page]); } catch { } };
        panel.Controls.Add(b);
    }
}

/// Address, error and yt-dlp output of one download.
public sealed class DetailsForm : Form
{
    public DetailsForm(DownloadItem item)
    {
        Ui.Setup(this, item.FileName, new Size(700, 460));
        FormBorderStyle = FormBorderStyle.Sizable;
        MinimizeBox = true;
        var text = new TextBox
        {
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Dock = DockStyle.Fill,
            Font = new Font("Consolas", 9f),
        };
        void Fill()
        {
            var lines = new List<string>
            {
                L.T("Address: ", "Adres: ") + item.Url,
                L.T("Status: ", "Durum: ") + item.State.Label() + (item.Stage.Length > 0 ? $" — {item.Stage}" : ""),
                L.T("Size: ", "Boyut: ") + $"{Fmt.Size(item.ReceivedBytes)} / {Fmt.Size(item.TotalBytes)}",
            };
            if (item.FinalPath != null) lines.Add(L.T("File: ", "Dosya: ") + item.FinalPath);
            if (item.ErrorMessage != null) lines.Add(L.T("Error: ", "Hata: ") + item.ErrorMessage);
            if (item.Segments.Count > 1) lines.Add(L.T("Connections: ", "Bağlantılar: ") + string.Join("  ", item.Segments.Select(s => $"{100.0 * s.Received / s.Length:0}%")));
            if (item.Log.Length > 0) { lines.Add(""); lines.Add(item.Log); }
            var t = string.Join(Environment.NewLine, lines).Replace("\n", Environment.NewLine).Replace("\r\r", "\r");
            if (text.Text != t) { text.Text = t; text.SelectionStart = t.Length; text.ScrollToCaret(); }
        }
        Fill();
        var timer = new System.Windows.Forms.Timer { Interval = 1000 };
        timer.Tick += (_, _) => Fill();
        timer.Start();
        FormClosed += (_, _) => timer.Dispose();
        Controls.Add(text);
    }
}
