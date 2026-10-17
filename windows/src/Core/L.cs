using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Markup;

namespace MCDM;

/// Localization: English source strings are the keys (same keys as the macOS app's Localizable.xcstrings),
/// Turkish comes from Resources/tr.json and is used when the Windows display language is Turkish.
/// Placeholders follow the macOS format: %@, %lld, %d and positional %1$@.
public static partial class L
{
    static readonly Dictionary<string, string>? Table = Load();

    static Dictionary<string, string>? Load()
    {
        if (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName != "tr") return null;
        using var s = typeof(L).Assembly.GetManifestResourceStream("tr.json");
        return s == null ? null : JsonSerializer.Deserialize<Dictionary<string, string>>(s);
    }

    public static string T(string key, params object[] args)
    {
        var fmt = Table != null && Table.TryGetValue(key, out var v) ? v : key;
        if (args.Length == 0) return fmt;
        int next = 0;
        return Placeholder().Replace(fmt, m =>
        {
            int i = m.Groups[1].Success ? int.Parse(m.Groups[1].Value) - 1 : next++;
            return i < args.Length ? Convert.ToString(args[i], CultureInfo.CurrentCulture) ?? "" : m.Value;
        });
    }

    [GeneratedRegex(@"%(?:(\d+)\$)?(?:@|lld|d)")]
    private static partial Regex Placeholder();
}

/// XAML: Text="{l:T 'Download folder'}"
public sealed class TExtension(string key) : MarkupExtension
{
    public override object ProvideValue(IServiceProvider serviceProvider) => L.T(key);
}
