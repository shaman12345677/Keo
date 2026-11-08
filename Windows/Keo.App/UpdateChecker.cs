using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Threading;

namespace Keo;

/// Stejný model jako Scanner na Windows: zjistit novou verzi a otevřít GitHub Releases ke stažení.
public static class UpdateChecker
{
    private static readonly HttpClient Http = CreateClient();

    public static async Task CheckAsync(Window owner, bool manual)
    {
        try
        {
            using var response = await Http.GetAsync(AppVersion.LatestApiUrl);
            if (!response.IsSuccessStatusCode)
            {
                if (manual)
                {
                    var open = await Confirm(
                        owner,
                        "Aktualizace",
                        "Nepodařilo se zjistit verzi na GitHubu (repo může být soukromé).",
                        "Otevřete stránku Releases a stáhněte nový zip, pokud je novější než " + AppVersion.Display + ".",
                        "Otevřít stahování",
                        "Zrušit");
                    if (open) OpenReleases();
                }
                return;
            }

            await using var stream = await response.Content.ReadAsStreamAsync();
            using var document = await JsonDocument.ParseAsync(stream);
            var tag = document.RootElement.GetProperty("tag_name").GetString() ?? "";
            var remote = Normalize(tag);
            var local = Normalize(AppVersion.Display);
            if (IsNewer(remote, local))
            {
                var open = await Confirm(
                    owner,
                    "Dostupná aktualizace",
                    $"Je dostupná nová verze {remote}.",
                    "Automatická instalace na Windows není k dispozici. Otevřete stahování a rozbalte nový zip přes starou složku.",
                    "Otevřít stahování",
                    "Později");
                if (open) OpenReleases(remote);
                return;
            }

            if (manual)
            {
                await Confirm(
                    owner,
                    "Aktualizace",
                    "Máte nejnovější verzi.",
                    $"Aktuální verze: {AppVersion.Display}",
                    "OK",
                    null);
            }
        }
        catch (Exception error)
        {
            if (!manual) return;
            var open = await Confirm(
                owner,
                "Chyba aktualizace",
                "Nepodařilo se zkontrolovat aktualizace.",
                error.Message,
                "Otevřít stahování",
                "Zrušit");
            if (open) OpenReleases();
        }
    }

    public static void OpenReleases(string? version = null)
    {
        var url = string.IsNullOrWhiteSpace(version)
            ? AppVersion.ReleasesUrl
            : $"{AppVersion.ReleasesUrl}/tag/v{Normalize(version)}";
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch
        {
            // Prohlížeč nejde spustit — uživatel otevře odkaz ručně.
        }
    }

    public static void Schedule(Window owner, int delayMs = 5000) =>
        _ = Task.Run(async () =>
        {
            await Task.Delay(delayMs);
            await Dispatcher.UIThread.InvokeAsync(() => CheckAsync(owner, manual: false));
        });

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(12) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Keo4Inventura", AppVersion.Display));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    private static string Normalize(string value)
    {
        var text = value.Trim();
        if (text.StartsWith("v", StringComparison.OrdinalIgnoreCase)) text = text[1..];
        return text;
    }

    private static bool IsNewer(string remote, string local)
    {
        var remoteVersion = Parse(remote);
        var localVersion = Parse(local);
        return remoteVersion is not null && localVersion is not null && remoteVersion > localVersion;
    }

    private static Version? Parse(string version)
    {
        var parts = Normalize(version).Split('.');
        if (parts.Length == 0 || !int.TryParse(parts[0], out var major)) return null;
        var minor = parts.Length > 1 && int.TryParse(parts[1], out var m) ? m : 0;
        var build = parts.Length > 2 && int.TryParse(parts[2], out var b) ? b : 0;
        return new Version(major, minor, build);
    }

    private static async Task<bool> Confirm(Window owner, string title, string message, string detail, string accept, string? cancel)
    {
        var dialog = new Window
        {
            Title = title,
            Width = 420,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false
        };
        var acceptClicked = false;
        var panel = new StackPanel { Margin = new Avalonia.Thickness(20), Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = message, TextWrapping = Avalonia.Media.TextWrapping.Wrap, FontWeight = Avalonia.Media.FontWeight.SemiBold });
        panel.Children.Add(new TextBlock { Text = detail, TextWrapping = Avalonia.Media.TextWrapping.Wrap, Opacity = 0.75 });
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right };
        var yes = new Button { Content = accept, MinWidth = 120 };
        yes.Click += (_, _) => { acceptClicked = true; dialog.Close(); };
        buttons.Children.Add(yes);
        if (cancel != null)
        {
            var no = new Button { Content = cancel, MinWidth = 90 };
            no.Click += (_, _) => dialog.Close();
            buttons.Children.Add(no);
        }
        panel.Children.Add(buttons);
        dialog.Content = panel;
        await dialog.ShowDialog(owner);
        return acceptClicked;
    }
}
