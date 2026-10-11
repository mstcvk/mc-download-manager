using System.Globalization;

namespace MCDownloadManager;

/// UI strings follow the Windows display language: Turkish when it is Turkish, English otherwise.
static class L
{
    public static readonly bool Turkish = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "tr";

    public static string T(string en, string tr) => Turkish ? tr : en;
}
