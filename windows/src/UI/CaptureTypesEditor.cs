using System.Windows;
using System.Windows.Controls;

namespace MCDM;

/// Category checkboxes + custom extensions. Used by the first-launch window and the Settings tab.
public sealed class CaptureTypesEditor : StackPanel
{
    public CaptureTypesEditor()
    {
        var settings = AppSettings.Shared;
        foreach (var g in CaptureTypes.Groups)
        {
            var box = new CheckBox
            {
                IsChecked = settings.CaptureGroupIds.Contains(g.Id),
                Margin = new Thickness(0, 4, 0, 4),
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = g.Category.Label() },
                        new TextBlock { Text = string.Join(", ", g.Extensions), Style = (Style)Application.Current.FindResource("Caption"), TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis },
                    },
                },
            };
            box.Click += (_, _) =>
            {
                settings.CaptureGroupIds.Remove(g.Id);
                if (box.IsChecked == true) settings.CaptureGroupIds.Add(g.Id);
                settings.Touch(nameof(AppSettings.CaptureGroupIds));
            };
            Children.Add(box);
        }
        Children.Add(new TextBlock { Text = L.T("Other extensions"), Margin = new Thickness(0, 10, 0, 4) });
        var custom = new TextBox { Text = settings.CustomExtensions, ToolTip = L.T("e.g. torrent, srt, ttf") };
        custom.TextChanged += (_, _) => settings.CustomExtensions = custom.Text;
        Children.Add(custom);
        Children.Add(new TextBlock { Text = L.T("e.g. torrent, srt, ttf"), Style = (Style)Application.Current.FindResource("Caption"), Margin = new Thickness(0, 4, 0, 0) });
    }
}
