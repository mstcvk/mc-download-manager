using System.Windows;

namespace MCDM;

public partial class AddDownloadWindow : Window
{
    public AddDownloadWindow()
    {
        InitializeComponent();
        SegmentsBox.Items.Add(L.T("Connections: default (%lld)", App.Settings.SegmentCount));
        for (int i = 1; i <= 16; i++) SegmentsBox.Items.Add(L.T("Connections: %lld", i));
        SegmentsBox.SelectedIndex = 0;
        try
        {
            var s = Clipboard.ContainsText() ? Clipboard.GetText().Trim() : "";
            if (s.StartsWith("http") && !s.Contains('\n')) UrlBox.Text = s;
        }
        catch { }
        Loaded += (_, _) => { UrlBox.Focus(); UrlBox.SelectAll(); };
    }

    void UrlBox_Changed(object sender, System.Windows.Controls.TextChangedEventArgs e) =>
        DownloadButton.IsEnabled = UrlBox.Text.Trim().Length > 0;

    void VideoBox_Click(object sender, RoutedEventArgs e) =>
        SegmentsRow.Visibility = VideoBox.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;

    void Paste_Click(object sender, RoutedEventArgs e)
    {
        try { if (Clipboard.ContainsText()) UrlBox.Text = Clipboard.GetText(); } catch { }
    }

    void Download_Click(object sender, RoutedEventArgs e)
    {
        int segments = SegmentsBox.SelectedIndex;
        App.Store.AddUrls(UrlBox.Text, VideoBox.IsChecked == true ? DownloadKind.Video : DownloadKind.File, segments == 0 ? null : segments);
        Close();
    }
}
