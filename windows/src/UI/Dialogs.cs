using System.Windows;
using System.Windows.Interop;
using WinForms = System.Windows.Forms;

namespace MCDM;

/// Native Windows task dialogs (the counterpart of NSAlert), always shown in front of other apps.
public static class Dialogs
{
    /// Returns the index of the clicked button (-1 when closed with Esc / X) and the checkbox state.
    public static (int Button, bool Checked) Ask(string heading, string text, string[] buttons, string? checkbox = null,
                                                 WinForms.TaskDialogIcon? icon = null)
    {
        var buttonObjects = buttons.Select(b => new WinForms.TaskDialogButton(b)).ToArray();
        var page = new WinForms.TaskDialogPage
        {
            Caption = "MC Download Manager",
            Heading = heading,
            Text = text,
            Icon = icon ?? WinForms.TaskDialogIcon.Information,
            AllowCancel = true,
            SizeToContent = true,
        };
        foreach (var b in buttonObjects) page.Buttons.Add(b);
        if (checkbox != null) page.Verification = new WinForms.TaskDialogVerificationCheckBox(checkbox);

        // A tiny topmost owner brings the dialog in front of the browser that triggered it.
        var owner = new Window
        {
            Width = 0, Height = 0, WindowStyle = WindowStyle.None, ShowInTaskbar = false, Topmost = true,
            ShowActivated = true, AllowsTransparency = true, Opacity = 0,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
        };
        owner.Show();
        owner.Activate();
        try
        {
            var result = WinForms.TaskDialog.ShowDialog(new WindowInteropHelper(owner).Handle, page, WinForms.TaskDialogStartupLocation.CenterOwner);
            return (Array.IndexOf(buttonObjects, result), page.Verification?.Checked == true);
        }
        finally
        {
            owner.Close();
        }
    }

    public static void Info(string heading, string text, bool error = false) =>
        Ask(heading, text, ["OK"], icon: error ? WinForms.TaskDialogIcon.Error : WinForms.TaskDialogIcon.Information);
}
