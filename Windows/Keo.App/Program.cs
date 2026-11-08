using Avalonia;
using System.Diagnostics;

namespace Keo;

sealed class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            WriteCrash(e.ExceptionObject?.ToString() ?? "unknown");
        try
        {
            BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        catch (Exception error)
        {
            WriteCrash(error.ToString());
            throw;
        }
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();

    private static void WriteCrash(string text)
    {
        try
        {
            var folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Keo");
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, "crash.log");
            File.WriteAllText(path, $"{DateTime.Now:O}\n{text}\n");
            Debug.WriteLine(text);
        }
        catch
        {
            // Když nejde zapsat log, necháme výjimku propadnout dál.
        }
    }
}
