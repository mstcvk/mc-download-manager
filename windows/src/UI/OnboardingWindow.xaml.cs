using System.Windows;

namespace MCDM;

/// First-launch flow: 1) file types  2) browser extensions (opens the guided wizard).
public partial class OnboardingWindow : Window
{
    int step;

    public OnboardingWindow()
    {
        InitializeComponent();
        BrowserList.ItemsSource = BrowserIntegration.InstalledBrowsers.Select(b => new { b.Name, b.Icon }).ToList();
        Closing += (_, _) => Finish();
        Render();
    }

    void Render()
    {
        Step0.Visibility = step == 0 ? Visibility.Visible : Visibility.Collapsed;
        Step1.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        BackButton.Visibility = NotNowButton.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        Subtitle.Text = step == 0 ? L.T("Which file types should be captured?") : L.T("Install the browser extensions?");
        PrimaryButton.Content = step == 0 ? L.T("Continue") : L.T("Start Setup");
    }

    void Back_Click(object sender, RoutedEventArgs e) { step = 0; Render(); }

    void Primary_Click(object sender, RoutedEventArgs e)
    {
        if (step == 0) { step = 1; Render(); return; }
        Close();
        Dispatcher.BeginInvoke(WizardWindow.ShowShared);
    }

    void NotNow_Click(object sender, RoutedEventArgs e) => Close();

    static void Finish()
    {
        var s = App.Settings;
        if (s.OnboardingDone) return;
        s.OnboardingDone = true;
        LoginItem.RegisterByDefaultIfNeeded();
        App.Store.PrepareDownloadFolder();
    }
}
