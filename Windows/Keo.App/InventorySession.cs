using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;

namespace Keo;

public sealed class RoomRow
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public int Done { get; init; }
    public int Total { get; init; }
    public GridLength DoneLength => new(Done, GridUnitType.Star);
    public GridLength RestLength => new(Math.Max(0, Total - Done), GridUnitType.Star);
    public string Count => $"{Done}/{Total}";
}

public sealed class CardRow
{
    public string Id { get; init; } = "";
    public string Number { get; init; } = "";
    public string Name { get; init; } = "";
    public string Status { get; init; } = "";
    public string StatusTitle { get; init; } = "";
    public string Place { get; init; } = "";
    public IBrush StatusBrush { get; init; } = Brushes.Gray;
}

public sealed class PhotoRow
{
    public string FileName { get; init; } = "";
    public Bitmap? Preview { get; init; }
}

public sealed class InventorySession : INotifyPropertyChanged
{
    private readonly string directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Keo", "session");
    private string PhotosDirectory => Path.Combine(directory, "photos");
    private InventoryBundle? bundle;
    private readonly Dictionary<string, CardChange> changes = new();
    private readonly List<SessionPhoto> photos = new();
    private int nextPhotoID = 1;
    private string fragment = "";
    private DateTime fragmentAt = DateTime.MinValue;
    private string lastCode = "";
    private DateTime lastAt = DateTime.MinValue;
    private DateTime acceptedAt = DateTime.MinValue;
    private string? selectedId;
    private string? placeId;
    private bool showAll = true;

    public ObservableCollection<RoomRow> Rooms { get; } = new();
    public ObservableCollection<CardRow> Cards { get; } = new();
    public ObservableCollection<Location> Places { get; } = new();
    public ObservableCollection<PhotoRow> DetailPhotos { get; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<string, bool>? ScanFeedback;

    public bool HasBundle => bundle != null;
    public string Description { get; private set; } = "";
    public string Filename { get; private set; } = "";
    public string Counts { get; private set; } = "";
    public string Notice { get; private set; } = "";
    public bool NoticeVisible { get; private set; }
    public string CardQuery { get; set; } = "";
    public string RoomQuery { get; set; } = "";
    public CardRow? SelectedCard { get; private set; }
    public string DetailNumber { get; private set; } = "";
    public string DetailName { get; private set; } = "";
    public string DetailStatus { get; private set; } = "";
    public string DetailPlace { get; private set; } = "";
    public string DetailMove { get; private set; } = "";
    public string DetailDate { get; private set; } = "";
    public string DetailType { get; private set; } = "";
    public string DetailPrice { get; private set; } = "";
    public string DetailRest { get; private set; } = "";
    public string DetailOrg { get; private set; } = "";
    public string DetailScanned { get; private set; } = "";
    public IBrush DetailStatusBrush { get; private set; } = Brushes.Gray;
    public bool DetailVisible => SelectedCard != null;

    public InventorySession() => Load();

    public void Import(string path)
    {
        var data = File.ReadAllBytes(path);
        bundle = InventoryBundle.Load(data, Path.GetFileName(path));
        changes.Clear();
        Directory.CreateDirectory(directory);
        File.WriteAllBytes(Path.Combine(directory, "inventory.zip"), data);
        File.WriteAllText(Path.Combine(directory, "meta.json"), JsonSerializer.Serialize(new SessionMeta(bundle.Filename)));
        SaveChanges();
        ResetPhotosDirectory();
        photos.Clear();
        photos.AddRange(ImportPhotos(bundle));
        nextPhotoID = (photos.Count == 0 ? 0 : photos.Max(photo => photo.LocalID)) + 1;
        SavePhotosMeta();
        showAll = true;
        placeId = null;
        selectedId = null;
        Refresh();
    }

    public byte[] ExportBytes(out string name)
    {
        if (bundle == null) throw new InventoryException("Není otevřená inventura.");
        name = $"keo4-export-{DateTime.Now:yyyyMMdd-HHmmss}.zip";
        return bundle.ExportZip(changes, ExportPhotos());
    }

    public bool AddPhoto(string cardID, byte[] imageData)
    {
        if (bundle == null || bundle.Cards.All(card => card.Id != cardID)) return false;
        var prepared = PhotoCodec.PrepareInventoryJpeg(imageData);
        if (prepared == null) return false;
        Directory.CreateDirectory(PhotosDirectory);
        var localID = nextPhotoID++;
        var fileName = CardPhotoExport.MakeFileName(localID);
        File.WriteAllBytes(Path.Combine(PhotosDirectory, fileName), prepared.Value.Full);
        File.WriteAllBytes(Path.Combine(PhotosDirectory, ThumbName(fileName)), prepared.Value.Thumb);
        photos.Add(new SessionPhoto(cardID, localID, fileName));
        SavePhotosMeta();
        if (selectedId == cardID) RefreshDetailPhotos();
        return true;
    }

    public void RemovePhoto(string fileName)
    {
        photos.RemoveAll(photo => photo.FileName == fileName);
        try { File.Delete(Path.Combine(PhotosDirectory, fileName)); } catch (Exception) { /* ignore */ }
        try { File.Delete(Path.Combine(PhotosDirectory, ThumbName(fileName))); } catch (Exception) { /* ignore */ }
        SavePhotosMeta();
        RefreshDetailPhotos();
    }

    public void ShowAll()
    {
        showAll = true;
        placeId = null;
        RefreshCards();
        OnChanged(nameof(HasBundle));
    }

    public void ShowRoom(string id)
    {
        showAll = false;
        placeId = id;
        RefreshCards();
    }

    public void SelectCard(string? id)
    {
        selectedId = id;
        RefreshDetail();
    }

    public void MarkFound() => Apply(selectedId, CardChange.Nalezeno());
    public void MarkMissing() => Apply(selectedId, CardChange.Nenalezeno());
    public void MarkMoved(string locationId) => Apply(selectedId, CardChange.Premisteni(locationId));

    public void ApplyFilter() => RefreshCards();
    public void ApplyRoomFilter() => RefreshRooms();

    public void HandleScan(string raw)
    {
        var piece = raw.Trim();
        if (piece.Length == 0 || Codes.Normalize(piece) == "v:2" || bundle == null) return;
        var trimmed = JoinFragment(piece);
        if (trimmed == lastCode && (DateTime.Now - lastAt).TotalSeconds < 2.2) return;
        if (!LooksLikeAsset(trimmed))
        {
            var rooms = ExactRooms(trimmed);
            if (rooms.Count == 1)
            {
                lastCode = trimmed;
                lastAt = DateTime.Now;
                ShowRoom(rooms[0].Id);
                SetNotice($"Místnost: {rooms[0].Label}");
                return;
            }
        }
        var hits = new CodeIndex(bundle.Cards).Match(trimmed);
        var current = CurrentCard();
        if (current != null && (DateTime.Now - acceptedAt).TotalSeconds < 2.5 && hits.All(card => card.Id != current.Id))
            return;
        if (hits.Count == 0)
        {
            if ((DateTime.Now - acceptedAt).TotalSeconds < 2.5) return;
            lastCode = trimmed;
            lastAt = DateTime.Now;
            SetNotice($"Není v inventuře: {trimmed}");
            return;
        }
        lastCode = trimmed;
        lastAt = DateTime.Now;
        var pool = hits;
        if (placeId != null)
        {
            var inRoom = hits.Where(card => (card.Umisteni?.Id ?? "") == placeId).ToList();
            if (inRoom.Count > 0) pool = inRoom;
        }
        if (pool.Count != 1)
        {
            SetNotice("Víc karet, vyberte ji v seznamu.");
            return;
        }
        Accept(pool[0]);
    }

    private void Accept(AssetCard item)
    {
        var state = CardState.Effective(item, changes.GetValueOrDefault(item.Id));
        var kept = CardState.ScanKeeps(state.Stav);
        if (!kept) Apply(item.Id, CardChange.Nalezeno(), notifyScan: false);
        selectedId = item.Id;
        acceptedAt = DateTime.Now;
        Refresh();
        var title = state.Stav == "PREMISTENI" ? "Přemístěno" : kept ? "Už bylo nalezeno" : "Nalezeno";
        SetNotice($"{title}: {item.Cislo} · {item.NazevMajetku}");
        ScanFeedback?.Invoke(title, kept);
    }

    private void Apply(string? id, CardChange change, bool notifyScan = true)
    {
        if (bundle == null || id == null) return;
        var card = bundle.Cards.FirstOrDefault(item => item.Id == id);
        if (card == null) return;
        if (CardState.MatchesOriginal(change, card)) changes.Remove(id);
        else changes[id] = change;
        SaveChanges();
        selectedId = id;
        Refresh();
        if (notifyScan) SetNotice($"{CardState.Title(change.Stav)}: {card.Cislo}");
    }

    private void Load()
    {
        var zipPath = Path.Combine(directory, "inventory.zip");
        if (!File.Exists(zipPath)) return;
        try
        {
            var metaPath = Path.Combine(directory, "meta.json");
            var filename = "Inventura.zip";
            if (File.Exists(metaPath))
                filename = JsonSerializer.Deserialize<SessionMeta>(File.ReadAllText(metaPath))?.Filename ?? filename;
            bundle = InventoryBundle.Load(File.ReadAllBytes(zipPath), filename);
            var changePath = Path.Combine(directory, "changes.json");
            if (File.Exists(changePath))
            {
                var stored = JsonSerializer.Deserialize<Dictionary<string, CardChangeDto>>(File.ReadAllText(changePath)) ?? new();
                foreach (var (id, dto) in stored)
                    changes[id] = new CardChange { Stav = dto.Stav, Oskenovano = dto.Oskenovano, NavrhPremisteniId = dto.NavrhPremisteniId };
            }
            LoadPhotosMeta();
            Refresh();
        }
        catch (Exception error)
        {
            SetNotice(error.Message);
        }
    }

    private void SaveChanges()
    {
        Directory.CreateDirectory(directory);
        var stored = changes.ToDictionary(
            pair => pair.Key,
            pair => new CardChangeDto(pair.Value.Stav, pair.Value.Oskenovano, pair.Value.NavrhPremisteniId));
        File.WriteAllText(Path.Combine(directory, "changes.json"), JsonSerializer.Serialize(stored));
    }

    private void Refresh()
    {
        Description = bundle?.Package.Description ?? "";
        Filename = bundle?.Filename ?? "";
        if (bundle == null) Counts = "";
        else
        {
            var progress = bundle.Progress(changes);
            Counts = $"{progress.Total} předmětů    {progress.Nalezeno} nalezeno    {progress.Premisteni} přemístěno    {progress.Nenalezeno} zbývá";
        }
        Places.Clear();
        if (bundle != null)
            foreach (var place in bundle.Locations.OrderBy(place => place.Label, StringComparer.CurrentCulture))
                Places.Add(place);
        RefreshRooms();
        RefreshCards();
        RefreshDetail();
        OnChanged(nameof(HasBundle));
        OnChanged(nameof(Description));
        OnChanged(nameof(Filename));
        OnChanged(nameof(Counts));
        OnChanged(nameof(DetailVisible));
    }

    private void RefreshRooms()
    {
        Rooms.Clear();
        if (bundle == null) return;
        var needle = RoomQuery.Trim();
        foreach (var group in bundle.LocationGroups(changes))
        {
            if (needle.Length > 0 && !group.Title.Contains(needle, StringComparison.CurrentCultureIgnoreCase)) continue;
            Rooms.Add(new RoomRow { Id = group.Id, Title = group.Title, Done = group.Done, Total = group.Total });
        }
    }

    private void RefreshCards()
    {
        Cards.Clear();
        if (bundle == null) return;
        var needle = Codes.Normalize(CardQuery);
        IEnumerable<AssetCard> source = bundle.Cards;
        if (!showAll && placeId != null)
            source = source.Where(card => (card.Umisteni?.Id ?? "") == placeId);
        foreach (var card in source.OrderBy(card => card.Cislo, StringComparer.CurrentCulture))
        {
            if (needle.Length > 0 && !Codes.Normalize(card.Cislo).Contains(needle) && !Codes.Normalize(card.NazevMajetku).Contains(needle))
                continue;
            var state = CardState.Effective(card, changes.GetValueOrDefault(card.Id));
            Cards.Add(new CardRow
            {
                Id = card.Id,
                Number = card.Cislo,
                Name = card.NazevMajetku,
                Status = state.Stav,
                StatusTitle = CardState.Title(state.Stav),
                Place = card.Umisteni?.Label ?? "Bez umístění",
                StatusBrush = state.Stav switch
                {
                    "NALEZENO" => new SolidColorBrush(Color.Parse("#34C759")),
                    "PREMISTENI" => new SolidColorBrush(Color.Parse("#FF9500")),
                    _ => Brushes.Gray
                }
            });
        }
        RefreshDetail();
    }

    private void RefreshDetail()
    {
        var card = CurrentCard();
        SelectedCard = card == null ? null : Cards.FirstOrDefault(row => row.Id == card.Id) ?? new CardRow { Id = card.Id, Number = card.Cislo, Name = card.NazevMajetku };
        if (card == null)
        {
            DetailNumber = DetailName = DetailStatus = DetailPlace = DetailMove = DetailDate = DetailType = DetailPrice = DetailRest = DetailOrg = DetailScanned = "";
            DetailStatusBrush = Brushes.Gray;
        }
        else
        {
            var state = CardState.Effective(card, changes.GetValueOrDefault(card.Id));
            var move = state.NavrhId == null ? null : bundle?.Locations.FirstOrDefault(place => place.Id == state.NavrhId) ?? card.Navrh;
            DetailNumber = card.Cislo;
            DetailName = card.NazevMajetku;
            DetailStatus = CardState.Title(state.Stav);
            DetailStatusBrush = state.Stav switch
            {
                "NALEZENO" => new SolidColorBrush(Color.Parse("#34C759")),
                "PREMISTENI" => new SolidColorBrush(Color.Parse("#FF9500")),
                _ => Brushes.Gray
            };
            DetailPlace = card.Umisteni?.Label ?? "Bez umístění";
            DetailMove = move?.Label ?? "";
            DetailDate = Format.Date(card.DatumZarazeni);
            DetailType = card.TypMajetku;
            DetailPrice = Format.Money(card.PorizCenaUcetni);
            DetailRest = Format.Money(card.ZustatkovaHodnota);
            DetailOrg = card.Organizace;
            DetailScanned = state.Oskenovano ? "Ano" : "Ne";
        }
        RefreshDetailPhotos();
        OnChanged(nameof(SelectedCard));
        OnChanged(nameof(DetailVisible));
        foreach (var name in new[] { nameof(DetailNumber), nameof(DetailName), nameof(DetailStatus), nameof(DetailStatusBrush), nameof(DetailPlace), nameof(DetailMove), nameof(DetailDate), nameof(DetailType), nameof(DetailPrice), nameof(DetailRest), nameof(DetailOrg), nameof(DetailScanned) })
            OnChanged(name);
    }

    public string? FullPhotoPath(string fileName)
    {
        var path = Path.Combine(PhotosDirectory, fileName);
        return File.Exists(path) ? path : null;
    }

    private void RefreshDetailPhotos()
    {
        foreach (var row in DetailPhotos)
            row.Preview?.Dispose();
        DetailPhotos.Clear();
        if (selectedId == null) return;
        foreach (var photo in photos.Where(item => item.CardID == selectedId).OrderBy(item => item.LocalID))
        {
            var thumbPath = Path.Combine(PhotosDirectory, ThumbName(photo.FileName));
            var fullPath = Path.Combine(PhotosDirectory, photo.FileName);
            var path = File.Exists(thumbPath) ? thumbPath : fullPath;
            Bitmap? preview = null;
            if (File.Exists(path))
            {
                try { preview = new Bitmap(path); } catch (Exception) { preview = null; }
            }
            DetailPhotos.Add(new PhotoRow { FileName = photo.FileName, Preview = preview });
        }
    }

    private List<CardPhoto> ExportPhotos()
    {
        var result = new List<CardPhoto>();
        foreach (var photo in photos)
        {
            var jpegPath = Path.Combine(PhotosDirectory, photo.FileName);
            if (!File.Exists(jpegPath)) continue;
            var jpeg = File.ReadAllBytes(jpegPath);
            var thumbPath = Path.Combine(PhotosDirectory, ThumbName(photo.FileName));
            byte[] thumb;
            if (File.Exists(thumbPath)) thumb = File.ReadAllBytes(thumbPath);
            else
            {
                var prepared = PhotoCodec.PrepareInventoryJpeg(jpeg);
                thumb = prepared?.Thumb ?? jpeg;
            }
            result.Add(new CardPhoto
            {
                CardID = photo.CardID,
                LocalID = photo.LocalID,
                FileName = photo.FileName,
                JpegData = jpeg,
                ThumbJpegData = thumb
            });
        }
        return result;
    }

    private void ResetPhotosDirectory()
    {
        if (Directory.Exists(PhotosDirectory))
            Directory.Delete(PhotosDirectory, recursive: true);
        Directory.CreateDirectory(PhotosDirectory);
        photos.Clear();
        nextPhotoID = 1;
    }

    private void SavePhotosMeta()
    {
        Directory.CreateDirectory(directory);
        var meta = new PhotosMeta(nextPhotoID, photos.Select(photo => new SessionPhotoDto(photo.CardID, photo.LocalID, photo.FileName)).ToList());
        File.WriteAllText(Path.Combine(directory, "photos.json"), JsonSerializer.Serialize(meta));
    }

    private void LoadPhotosMeta()
    {
        photos.Clear();
        nextPhotoID = 1;
        var path = Path.Combine(directory, "photos.json");
        if (!File.Exists(path)) return;
        try
        {
            var meta = JsonSerializer.Deserialize<PhotosMeta>(File.ReadAllText(path));
            if (meta == null) return;
            nextPhotoID = Math.Max(1, meta.NextID);
            foreach (var item in meta.Photos)
            {
                if (!File.Exists(Path.Combine(PhotosDirectory, item.FileName))) continue;
                photos.Add(new SessionPhoto(item.CardID, item.LocalID, item.FileName));
            }
            if (photos.Count > 0)
                nextPhotoID = Math.Max(nextPhotoID, photos.Max(photo => photo.LocalID) + 1);
        }
        catch (Exception)
        {
            photos.Clear();
            nextPhotoID = 1;
        }
    }

    private List<SessionPhoto> ImportPhotos(InventoryBundle loaded)
    {
        var imported = new List<SessionPhoto>();
        var xmlEntry = loaded.Entries.FirstOrDefault(entry => Path.GetFileName(entry.Name) == "FotkyInventarizovaneKarty.xml");
        var xml = xmlEntry == null ? "" : Encoding.UTF8.GetString(xmlEntry.Data);
        var links = ParsePhotoLinks(xml);
        Directory.CreateDirectory(PhotosDirectory);
        foreach (var entry in loaded.Entries.Where(item => item.Name.StartsWith("photos/", StringComparison.Ordinal)
                     && item.Name.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase)))
        {
            var fileName = Path.GetFileName(entry.Name);
            if (!links.TryGetValue(entry.Name, out var cardID) && !links.TryGetValue($"photos/{fileName}", out cardID))
                continue;
            var prepared = PhotoCodec.PrepareInventoryJpeg(entry.Data);
            if (prepared == null) continue;
            var localID = NextImportID(fileName, imported.Count + 1);
            File.WriteAllBytes(Path.Combine(PhotosDirectory, fileName), prepared.Value.Full);
            File.WriteAllBytes(Path.Combine(PhotosDirectory, ThumbName(fileName)), prepared.Value.Thumb);
            imported.Add(new SessionPhoto(cardID, localID, fileName));
        }
        return imported.OrderBy(photo => photo.LocalID).ToList();
    }

    private static int NextImportID(string fileName, int fallback)
    {
        var parts = fileName.Split('_');
        if (parts.Length >= 2 && int.TryParse(parts[1], out var value)) return value;
        return fallback;
    }

    private static Dictionary<string, string> ParsePhotoLinks(string xml)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var search = 0;
        while (true)
        {
            var open = xml.IndexOf("<MblFotkaInventarizovaneKarty>", search, StringComparison.Ordinal);
            if (open < 0) break;
            var close = xml.IndexOf("</MblFotkaInventarizovaneKarty>", open, StringComparison.Ordinal);
            if (close < 0) break;
            var slice = xml[open..close];
            var cardBlock = FirstBlock("inventarizovanaKarta", slice) ?? "";
            var cardID = FirstTag("id", cardBlock) ?? "";
            var zipPath = FirstTag("zipPath", slice) ?? "";
            if (cardID.Length > 0 && zipPath.Length > 0)
                result[zipPath] = cardID;
            search = close + 1;
        }
        return result;
    }

    private static string? FirstBlock(string name, string xml)
    {
        var open = xml.IndexOf($"<{name}>", StringComparison.Ordinal);
        if (open < 0) return null;
        open += name.Length + 2;
        var close = xml.IndexOf($"</{name}>", open, StringComparison.Ordinal);
        return close < 0 ? null : xml[open..close];
    }

    private static string? FirstTag(string name, string xml)
    {
        var open = xml.IndexOf($"<{name}>", StringComparison.Ordinal);
        if (open < 0) return null;
        open += name.Length + 2;
        var close = xml.IndexOf($"</{name}>", open, StringComparison.Ordinal);
        return close < 0 ? null : xml[open..close];
    }

    private static string ThumbName(string fileName) =>
        Path.GetFileNameWithoutExtension(fileName) + ".thumb.jpg";

    private AssetCard? CurrentCard() => bundle?.Cards.FirstOrDefault(card => card.Id == selectedId);

    private void SetNotice(string text)
    {
        Notice = text;
        NoticeVisible = true;
        OnChanged(nameof(Notice));
        OnChanged(nameof(NoticeVisible));
    }

    private string JoinFragment(string piece)
    {
        var recent = (DateTime.Now - fragmentAt).TotalSeconds < 2 && fragment.Length > 0;
        var joined = recent && LooksLikeContinuation(piece) ? fragment + "\n" + piece : piece;
        fragment = joined;
        fragmentAt = DateTime.Now;
        return joined;
    }

    private static bool LooksLikeContinuation(string piece)
    {
        var first = piece.Split('\n', '\r').FirstOrDefault()?.Trim() ?? piece;
        if (first.Length == 0) return true;
        if (System.Text.RegularExpressions.Regex.IsMatch(first, @"^\d{1,2}\.\d{1,2}\.\d{4}")) return true;
        var token = Codes.Normalize(first);
        if (token == "v:2" || token.EndsWith("v:2", StringComparison.Ordinal)) return true;
        return first.Contains('.') && System.Text.RegularExpressions.Regex.IsMatch(first, @"\d{2}\.\d{2}\.\d{4}");
    }

    private static bool LooksLikeAsset(string raw) =>
        raw.Contains('\n') || raw.Contains('\r') || raw.Contains("v:2", StringComparison.OrdinalIgnoreCase);

    private List<Location> ExactRooms(string raw)
    {
        if (bundle == null) return new();
        var whole = Codes.Normalize(raw);
        if (whole.Length == 0 || whole == "v:2") return new();
        return new LocationIndex(bundle.Locations).Match(raw).Where(room =>
        {
            var keys = new[]
            {
                room.Id, room.KodUtvaru, room.KodMistnosti, room.Nazev,
                $"{room.KodUtvaru}/{room.KodMistnosti}", room.KodUtvaru + room.KodMistnosti
            }.Select(Codes.Normalize);
            return keys.Contains(whole);
        }).ToList();
    }

    private void OnChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private sealed record SessionMeta(string Filename);
    private sealed record CardChangeDto(string Stav, bool Oskenovano, string? NavrhPremisteniId);
    private sealed record SessionPhoto(string CardID, int LocalID, string FileName);
    private sealed record SessionPhotoDto(string CardID, int LocalID, string FileName);
    private sealed record PhotosMeta(int NextID, List<SessionPhotoDto> Photos);
}
