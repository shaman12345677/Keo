using System.Media;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Keo;

public partial class MainWindow : Window
{
    private readonly InventorySession session;
    private readonly ScanBurstAssembler burst = new() { Idle = 1.2 };
    private readonly DispatcherTimer clock;
    private bool scanning;
    private string? previewFileName;
    private Bitmap? previewBitmap;

    public MainWindow(InventorySession session)
    {
        this.session = session;
        InitializeComponent();
        TrySetIcon();
        DataContext = session;
        VersionLabel.Text = AppVersion.Display;
        session.ScanFeedback += PlayScan;
        Opened += (_, _) => UpdateChecker.Schedule(this);
        clock = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        clock.Tick += (_, _) =>
        {
            if (OperatingSystem.IsWindows()) return;
            foreach (var step in burst.Tick(DateTime.Now.TimeOfDay.TotalSeconds))
                if (step.Kind == ScanBurstKind.CommitIdle && step.Text.Length > 0)
                    session.HandleScan(step.Text);
        };
        clock.Start();
        Opened += (_, _) => WinScanner.Install(
            burst,
            () => scanning,
            () => FocusManager?.GetFocusedElement() is TextBox,
            text => Dispatcher.UIThread.Post(() => session.HandleScan(text)));
        Closed += (_, _) => WinScanner.Remove();
        AddHandler(KeyDownEvent, OnKey, RoutingStrategies.Tunnel);
        ImportButton.Click += async (_, _) => await Import();
        ExportButton.Click += async (_, _) => await Export();
        ScanToggle.IsCheckedChanged += (_, _) =>
        {
            scanning = ScanToggle.IsChecked == true;
            ScanToggle.Content = scanning ? "Skenování zapnuto" : "Skenování vypnuto";
            // Čtečka posílá Enter/mezerník — nesmí znovu „kliknout“ na fokusované tlačítko.
            if (scanning) FocusManager?.ClearFocus();
        };
        AllRooms.Click += (_, _) =>
        {
            Rooms.SelectedItem = null;
            session.ShowAll();
        };
        RoomSearch.TextChanged += (_, _) =>
        {
            session.RoomQuery = RoomSearch.Text ?? "";
            session.ApplyRoomFilter();
        };
        CardSearch.TextChanged += (_, _) =>
        {
            session.CardQuery = CardSearch.Text ?? "";
            session.ApplyFilter();
        };
        Rooms.SelectionChanged += (_, _) =>
        {
            if (Rooms.SelectedItem is RoomRow room) session.ShowRoom(room.Id);
        };
        Cards.SelectionChanged += (_, _) =>
        {
            session.SelectCard((Cards.SelectedItem as CardRow)?.Id);
        };
        FoundButton.Click += (_, _) => session.MarkFound();
        MissingButton.Click += (_, _) => session.MarkMissing();
        MoveButton.Click += (_, _) =>
        {
            if (MovePlace.SelectedItem is Location place) session.MarkMoved(place.Id);
        };
        AddPhotoButton.Click += async (_, _) => await AddPhotoFromAlbum();
        Closed += (_, _) => ClosePhotoPreview();
    }

    private void OnDeletePhotoClick(object? sender, RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string fileName })
        {
            if (previewFileName == fileName) ClosePhotoPreview();
            session.RemovePhoto(fileName);
        }
    }

    private void OnPhotoPreviewPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        if (sender is not Control { Tag: string fileName }) return;
        ShowPhotoPreview(fileName);
        e.Handled = true;
    }

    private void OnPhotoOverlayBackgroundPressed(object? sender, PointerPressedEventArgs e)
    {
        // Klik mimo tlačítka zavře náhled.
        for (var c = e.Source as Control; c != null; c = c.Parent as Control)
            if (c is Button) return;
        ClosePhotoPreview();
        e.Handled = true;
    }

    private void OnPhotoPreviewCloseClick(object? sender, RoutedEventArgs e) => ClosePhotoPreview();

    private void OnPhotoPreviewDeleteClick(object? sender, RoutedEventArgs e)
    {
        if (previewFileName is not { } fileName) return;
        ClosePhotoPreview();
        session.RemovePhoto(fileName);
    }

    private void ShowPhotoPreview(string fileName)
    {
        var path = session.FullPhotoPath(fileName);
        if (path == null) return;
        Bitmap bitmap;
        try { bitmap = new Bitmap(path); }
        catch (Exception) { return; }
        previewBitmap?.Dispose();
        previewBitmap = bitmap;
        previewFileName = fileName;
        PhotoPreviewImage.Source = bitmap;
        PhotoPreviewOverlay.IsVisible = true;
    }

    private void ClosePhotoPreview()
    {
        PhotoPreviewOverlay.IsVisible = false;
        PhotoPreviewImage.Source = null;
        previewBitmap?.Dispose();
        previewBitmap = null;
        previewFileName = null;
    }

    private async Task AddPhotoFromAlbum()
    {
        if (session.SelectedCard == null) return;
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Fotografie majetku",
            AllowMultiple = true,
            FileTypeFilter = new[]
            {
                new FilePickerFileType("Obrázky")
                {
                    Patterns = new[] { "*.jpg", "*.jpeg", "*.png", "*.heic", "*.webp", "*.bmp" }
                }
            }
        });
        if (files.Count == 0) return;
        var cardID = session.SelectedCard.Id;
        foreach (var file in files)
        {
            await using var stream = await file.OpenReadAsync();
            using var memory = new MemoryStream();
            await stream.CopyToAsync(memory);
            session.AddPhoto(cardID, memory.ToArray());
        }
    }

    private void OnKey(object? sender, KeyEventArgs e)
    {
        if (OperatingSystem.IsWindows()) return;
        if (e.Key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin) return;
        var editing = FocusManager?.GetFocusedElement() is TextBox;
        if (!scanning)
        {
            if (!editing && e.KeyModifiers == KeyModifiers.None) e.Handled = true;
            return;
        }
        if (e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Meta)) return;
        var time = DateTime.Now.TimeOfDay.TotalSeconds;
        if (UsKeys.IsAvaloniaTerminator(e.Key))
        {
            foreach (var step in burst.PushTerminator(time))
                if (step.Kind == ScanBurstKind.CommitIdle) session.HandleScan(step.Text);
            e.Handled = true;
            return;
        }
        var character = UsKeys.FromAvalonia(e.Key, e.KeyModifiers.HasFlag(KeyModifiers.Shift));
        if (character == null)
        {
            e.Handled = true;
            return;
        }
        foreach (var step in burst.PushForced(character.Value, time))
            if (step.Kind == ScanBurstKind.CommitIdle) session.HandleScan(step.Text);
        e.Handled = true;
    }

    private void TrySetIcon()
    {
        try
        {
            using var stream = AssetLoader.Open(new Uri("avares://Keo4Inventura/Assets/AppIcon.ico"));
            Icon = new WindowIcon(stream);
        }
        catch (Exception)
        {
            try
            {
                using var stream = AssetLoader.Open(new Uri("avares://Keo4Inventura/Assets/AppIcon.png"));
                Icon = new WindowIcon(stream);
            }
            catch (Exception)
            {
                // Bez ikony aplikace pořád běží.
            }
        }
    }

    private async Task Import()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Inventura.zip",
            AllowMultiple = false,
            FileTypeFilter = new[] { new FilePickerFileType("Inventura") { Patterns = new[] { "*.zip" } } }
        });
        var file = files.FirstOrDefault();
        if (file == null) return;
        await using var stream = await file.OpenReadAsync();
        using var memory = new MemoryStream();
        await stream.CopyToAsync(memory);
        var temp = Path.Combine(Path.GetTempPath(), file.Name);
        await File.WriteAllBytesAsync(temp, memory.ToArray());
        session.Import(temp);
    }

    private async Task Export()
    {
        if (!session.HasBundle) return;
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export pro KEO4",
            SuggestedFileName = $"keo4-export-{DateTime.Now:yyyyMMdd-HHmmss}.zip",
            FileTypeChoices = new[] { new FilePickerFileType("Inventura") { Patterns = new[] { "*.zip" } } }
        });
        if (file == null) return;
        var bytes = session.ExportBytes(out _);
        await using var stream = await file.OpenWriteAsync();
        await stream.WriteAsync(bytes);
    }

    private static void PlayScan(string title, bool already)
    {
        if (!OperatingSystem.IsWindows()) return;
        if (title.StartsWith("Místnost", StringComparison.Ordinal) || title.StartsWith("Není", StringComparison.Ordinal) || title.StartsWith("Víc", StringComparison.Ordinal))
            return;
        try
        {
            using var player = new SoundPlayer(Tone(already ? 520 : 880, already ? 0.08 : 0.14));
            player.Play();
        }
        catch (Exception)
        {
            // Zvuk je jen odezva. Inventura zůstane označená i když ho Windows nepustí.
        }
    }

    private static MemoryStream Tone(double frequency, double seconds)
    {
        const int rate = 22050;
        var count = (int)(rate * seconds);
        var data = new byte[count * 2];
        for (var i = 0; i < count; i++)
        {
            var envelope = Math.Min(1, (count - i) / (rate * 0.03));
            var sample = (short)(Math.Sin(2 * Math.PI * frequency * i / rate) * 12000 * envelope);
            data[i * 2] = (byte)(sample & 0xff);
            data[i * 2 + 1] = (byte)((sample >> 8) & 0xff);
        }
        var stream = new MemoryStream();
        using (var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, leaveOpen: true))
        {
            writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(36 + data.Length);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
            writer.Write(16);
            writer.Write((short)1);
            writer.Write((short)1);
            writer.Write(rate);
            writer.Write(rate * 2);
            writer.Write((short)2);
            writer.Write((short)16);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
            writer.Write(data.Length);
            writer.Write(data);
        }
        stream.Position = 0;
        return stream;
    }
}
