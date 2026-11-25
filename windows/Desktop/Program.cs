using System.Diagnostics;
using System.Drawing;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new StudioWindow());
    }
}

internal sealed class StudioWindow : Form
{
    private readonly WebView2 view = new() { Dock = DockStyle.Fill };
    private readonly Label status = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter };
    private readonly Button retry = new() { Dock = DockStyle.Bottom, Height = 42, Text = "Erneut verbinden" };
    private readonly Uri bridge = new("http://localhost:8765/");
    private readonly string home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ButchiesKI");
    private readonly HashSet<string> origins = new(StringComparer.OrdinalIgnoreCase);
    private bool initialized;

    internal StudioWindow()
    {
        Text = "Butchies KI Studio";
        Size = new Size(1400, 900);
        MinimumSize = new Size(660, 520);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(232, 244, 253);
        using var icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        if (icon != null) Icon = (Icon)icon.Clone();
        Controls.Add(view);
        Controls.Add(status);
        Controls.Add(retry);
        retry.Click += async (_, _) => await Connect();
        Shown += async (_, _) => await Connect();
    }

    private void ShowStatus(string message, bool canRetry)
    {
        status.Text = message;
        status.Visible = true;
        retry.Visible = canRetry;
        view.Visible = false;
    }

    private async Task Connect()
    {
        ShowStatus("Verbinde mit Butchies KI Studio …", false);
        try
        {
            if (!initialized)
            {
                var environment = await CoreWebView2Environment.CreateAsync(
                    userDataFolder: Path.Combine(home, "desktop-profile"));
                await view.EnsureCoreWebView2Async(environment);
                view.CoreWebView2.Settings.AreDevToolsEnabled = false;
                view.CoreWebView2.NavigationStarting += (_, e) =>
                {
                    if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) || !Allowed(uri)) e.Cancel = true;
                };
                view.CoreWebView2.LaunchingExternalUriScheme += (_, e) =>
                {
                    e.Cancel = true;
                    if (e.IsUserInitiated && e.Uri == "butchies-ki-ssh:") OpenExternal(e.Uri);
                };
                view.CoreWebView2.NewWindowRequested += (_, e) =>
                {
                    e.Handled = true;
                    if (e.IsUserInitiated && Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri)
                        && uri.Scheme is "https" or "http") OpenExternal(uri.AbsoluteUri);
                };
                view.CoreWebView2.NavigationCompleted += (_, e) =>
                {
                    if (!e.IsSuccess && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                        ShowStatus("Studio nicht erreichbar. Prüfe den Mini-PC und die Taskleisten-App.", true);
                };
                initialized = true;
            }
            origins.Clear();
            origins.Add(bridge.GetLeftPart(UriPartial.Authority));
            var config = Path.Combine(home, "taskleiste.json");
            if (File.Exists(config))
            {
                var json = new System.Web.Script.Serialization.JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(File.ReadAllText(config));
                foreach (var key in new[] { "host", "ip" })
                    if (json.TryGetValue(key, out var item) && item is string value
                        && Uri.TryCreate("http://" + value, UriKind.Absolute, out var uri)
                        && uri.UserInfo.Length == 0)
                        origins.Add(uri.GetLeftPart(UriPartial.Authority));
            }
            origins.Add("http://butchies-ki");
            status.Visible = retry.Visible = false;
            view.Visible = true;
            view.CoreWebView2.Navigate(bridge.AbsoluteUri);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            ShowStatus("Microsoft Edge WebView2 Runtime fehlt. Installiere die Runtime und versuche es erneut.", true);
        }
        catch (Exception e)
        {
            ShowStatus("Studio konnte nicht geöffnet werden.\n" + e.Message, true);
        }
    }

    private bool Allowed(Uri uri) => uri.Scheme is "http" or "https"
        && origins.Contains(uri.GetLeftPart(UriPartial.Authority));

    private void OpenExternal(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { MessageBox.Show(this, e.Message, "Butchies KI Studio"); }
    }
}
