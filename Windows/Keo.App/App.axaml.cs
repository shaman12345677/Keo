using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace Keo;

public class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var session = new InventorySession();
            var window = new MainWindow(session);
            desktop.MainWindow = window;
            var zip = desktop.Args?.FirstOrDefault(argument => argument.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));
            if (zip != null && File.Exists(zip)) session.Import(zip);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
