using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
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
    private bool autoLoginAttempted;

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
                view.CoreWebView2.Settings.IsPasswordAutosaveEnabled = false;
                view.CoreWebView2.Settings.IsGeneralAutofillEnabled = false;
                view.CoreWebView2.WebResourceResponseReceived += (_, e) =>
                {
                    if (e.Response.StatusCode == 200 && Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out var uri)
                        && Allowed(uri) && uri.AbsolutePath == "/api/logout")
                    {
                        try { File.WriteAllText(Path.Combine(home, "desktop-autologin-paused"), ""); }
                        catch (IOException) { }
                        catch (UnauthorizedAccessException) { }
                    }
                };
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
                        if (await TrySavedLogin()) return;
                        if (closing || IsDisposed) return;
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

    private async Task<bool> TrySavedLogin()
    {
        if (autoLoginAttempted || !Uri.TryCreate(view.CoreWebView2.Source, UriKind.Absolute, out var uri)
            || !Allowed(uri) || uri.IsLoopback || uri.AbsolutePath != "/") return false;
        autoLoginAttempted = true;
        try
        {
            var origin = new Uri(uri.GetLeftPart(UriPartial.Authority));
            // Nur der im Windows-Profil hinterlegte Server ist für das gespeicherte Passwort zulässig.
            var config = new System.Web.Script.Serialization.JavaScriptSerializer()
                .Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(home, "taskleiste.json")));
            if (!config.TryGetValue("host", out var host) || host is not string configured
                || !string.Equals(configured, uri.Host, StringComparison.OrdinalIgnoreCase)
                || !uri.IsDefaultPort) return false;
            var pausePath = Path.Combine(home, "desktop-autologin-paused");
            var manager = view.CoreWebView2.CookieManager;
            using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false };
            foreach (var cookie in await manager.GetCookiesAsync(origin.AbsoluteUri))
                if (cookie.Name == "bki") handler.CookieContainer.Add(origin, new Cookie(cookie.Name, cookie.Value, "/"));
            using var client = new HttpClient(handler) { BaseAddress = origin, Timeout = TimeSpan.FromSeconds(4) };
            using var state = await client.GetAsync("/api/state");
            if (!state.IsSuccessStatusCode) return false;
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            var server = serializer.Deserialize<Dictionary<string, object>>(await state.Content.ReadAsStringAsync());
            if (server.TryGetValue("logged_in", out var loggedIn) && Equals(loggedIn, true))
            {
                if (File.Exists(pausePath)) File.Delete(pausePath);
                return false;
            }
            if (File.Exists(pausePath)) return false;
            var saved = Path.Combine(home, "passwort.dat");
            if (!File.Exists(saved)) return false;
            var hex = File.ReadAllText(saved).Trim();
            if (hex.Length % 2 != 0 || !Regex.IsMatch(hex, "^[0-9a-fA-F]{2,8192}$")) return false;
            var encrypted = new byte[hex.Length / 2];
            for (var i = 0; i < encrypted.Length; i++) encrypted[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            var clear = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            string password;
            try { password = Encoding.Unicode.GetString(clear); }
            finally { Array.Clear(clear, 0, clear.Length); }
            if (password.Length == 0 || password == "0000") return false;
            using var body = new StringContent(serializer.Serialize(new { password, remember = true }), Encoding.UTF8, "application/json");
            using var login = await client.PostAsync("/api/login", body);
            if (!login.IsSuccessStatusCode || closing || IsDisposed) return false;
            var session = handler.CookieContainer.GetCookies(origin)["bki"];
            if (session == null || string.IsNullOrEmpty(session.Value)) return false;
            var webCookie = manager.CreateCookie("bki", session.Value, uri.Host, "/");
            webCookie.IsHttpOnly = true;
            webCookie.SameSite = CoreWebView2CookieSameSiteKind.Strict;
            webCookie.IsSecure = uri.Scheme == "https";
            if (session.Expires != DateTime.MinValue) webCookie.Expires = session.Expires.ToUniversalTime();
            manager.AddOrUpdateCookie(webCookie);
            view.CoreWebView2.Reload();
            return true;
        }
        catch (Exception)
        {
            // Anmeldung bleibt bei ungültigem Passwort oder fehlender Verbindung manuell verfügbar.
            return false;
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
