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
    private readonly LaunchPanel status = new() { Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 16 };
    private readonly Stopwatch transition = new();
    private readonly bool animate = SystemInformation.IsMenuAnimationEnabled;
    private bool closing;
    private bool closeReady;
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
        if (animate) Opacity = 0;
        animation.Tick += Animate;
        Shown += async (_, _) =>
        {
            transition.Restart();
            if (animate) animation.Start();
            await Connect();
        };
        FormClosed += (_, _) => animation.Dispose();
    }

    private void Animate(object? sender, EventArgs e)
    {
        var duration = closing ? 240d : 350d;
        var progress = Math.Min(1, transition.Elapsed.TotalMilliseconds / duration);
        var eased = progress * progress * (3 - 2 * progress);
        Opacity = closing ? 1 - eased : eased;
        if (status.Visible && !closing)
        {
            status.Phase = transition.Elapsed.TotalMilliseconds / 280;
            status.Invalidate();
        }
        if (progress < 1) return;
        if (closing)
        {
            animation.Stop();
            closeReady = true;
            Close();
        }
        else if (!status.Visible)
        {
            animation.Stop();
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (animate && !closeReady && e.CloseReason == CloseReason.UserClosing && (closing || Opacity > .95))
        {
            e.Cancel = true;
            if (!closing)
            {
                closing = true;
                transition.Restart();
                animation.Start();
            }
        }
        base.OnFormClosing(e);
    }

    private void ShowStatus(string message, bool canRetry)
    {
        if (closing || IsDisposed) return;
        status.Text = message;
        status.Invalidate();
        status.Visible = true;
        status.BringToFront();
        retry.BringToFront();
        if (animate) animation.Start();
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
                if (closing || IsDisposed) return;
                await view.EnsureCoreWebView2Async(environment);
                if (closing || IsDisposed) return;
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
                view.CoreWebView2.NavigationCompleted += async (_, e) =>
                {
                    if (closing || IsDisposed) return;
                    if (e.IsSuccess)
                    {
                        var remaining = animate ? 450 - (int)transition.ElapsedMilliseconds : 0;
                        if (remaining > 0) await Task.Delay(remaining);
                        if (closing || IsDisposed) return;
                        status.Visible = retry.Visible = false;
                        view.Visible = true;
                    }
                    else if (e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                    {
                        ShowStatus("Studio nicht erreichbar. Prüfe den Mini-PC und die Taskleisten-App.", true);
                    }
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
            if (closing || IsDisposed) return;
            retry.Visible = false;
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

internal sealed class LaunchPanel : Control
{
    internal double Phase { get; set; }

    internal LaunchPanel()
    {
        DoubleBuffered = true;
        BackColor = Color.FromArgb(232, 244, 253);
        ForeColor = Color.FromArgb(16, 44, 76);
        ResizeRedraw = true;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var x = ClientSize.Width / 2;
        var y = ClientSize.Height / 2 - 24;
        var mark = new Rectangle(x - 31, y - 84, 62, 62);
        using var blue = new SolidBrush(Color.FromArgb(8, 117, 199));
        using var title = new Font(Font.FontFamily, 22, FontStyle.Bold);
        using var markFont = new Font(Font.FontFamily, 29, FontStyle.Bold);
        g.FillEllipse(blue, mark);
        TextRenderer.DrawText(g, "B", markFont, mark, Color.White,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        var center = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter;
        TextRenderer.DrawText(g, "Butchies KI Studio", title, new Rectangle(12, y - 9, Width - 24, 42), ForeColor, center);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(24, y + 35, Width - 48, 56), ForeColor,
            center | TextFormatFlags.WordBreak);
        for (var i = 0; i < 3; i++)
        {
            var alpha = 75 + (int)(170 * (.5 + .5 * Math.Cos(Phase - i * 1.5)));
            using var dot = new SolidBrush(Color.FromArgb(alpha, blue.Color));
            g.FillEllipse(dot, x - 20 + i * 16, y + 100, 8, 8);
        }
    }
}
