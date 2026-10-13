using System.ComponentModel;
using System.Windows;
using System.Windows.Media;

namespace MCDM;

/// Bar showing how much of each segment has been received.
public sealed class SegmentBar : FrameworkElement
{
    static readonly Brush Accent = Frozen(Color.FromRgb(0x2F, 0x6F, 0xEB));
    static readonly Brush Paused = Frozen(Color.FromRgb(0xF5, 0xA6, 0x23));
    static readonly Brush Failed = Frozen(Color.FromRgb(0xE5, 0x48, 0x4D));
    static readonly Brush Track = Frozen(Color.FromArgb(0x40, 0x80, 0x80, 0x80));
    static readonly Brush Divider = Frozen(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF));

    static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    public static readonly DependencyProperty ItemProperty = DependencyProperty.Register(
        nameof(Item), typeof(DownloadItem), typeof(SegmentBar), new PropertyMetadata(null, OnItemChanged));

    public DownloadItem? Item
    {
        get => (DownloadItem?)GetValue(ItemProperty);
        set => SetValue(ItemProperty, value);
    }

    static void OnItemChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var bar = (SegmentBar)d;
        if (e.OldValue is DownloadItem old) old.PropertyChanged -= bar.Redraw;
        if (e.NewValue is DownloadItem item) item.PropertyChanged += bar.Redraw;
        bar.InvalidateVisual();
    }

    void Redraw(object? sender, PropertyChangedEventArgs e) => InvalidateVisual();

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0 || Item is not { } item) return;
        var shape = new RectangleGeometry(new Rect(0, 0, w, h), h / 2, h / 2);
        dc.DrawGeometry(Track, null, shape);
        dc.PushClip(shape);
        var tint = item.State switch
        {
            DownloadState.Paused => Paused,
            DownloadState.Failed => Failed,
            _ => Accent,
        };
        var segs = item.Segments;
        long total = item.TotalBytes;
        if (segs.Count == 0 || total <= 0)
        {
            dc.DrawRectangle(tint, null, new Rect(0, 0, w * item.Progress, h));
        }
        else
        {
            foreach (var s in segs.Where(s => s.Received > 0))
                dc.DrawRectangle(tint, null, new Rect((double)s.Start / total * w, 0, Math.Max((double)s.Received / total * w, 1), h));
            foreach (var s in segs.Skip(1))
                dc.DrawRectangle(Divider, null, new Rect((double)s.Start / total * w, 0, 1, h));
        }
        dc.Pop();
    }
}
