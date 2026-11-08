using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Media;

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

public sealed class InventorySession : INotifyPropertyChanged
{
    private readonly string directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Keo", "session");
    private InventoryBundle? bundle;
    private readonly Dictionary<string, CardChange> changes = new();
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
        showAll = true;
        placeId = null;
        selectedId = null;
        Refresh();
    }

    public byte[] ExportBytes(out string name)
    {
        if (bundle == null) throw new InventoryException("Není otevřená inventura.");
        name = $"keo4-export-{DateTime.Now:yyyyMMdd-HHmmss}.zip";
        return bundle.ExportZip(changes);
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
        OnChanged(nameof(SelectedCard));
        OnChanged(nameof(DetailVisible));
        foreach (var name in new[] { nameof(DetailNumber), nameof(DetailName), nameof(DetailStatus), nameof(DetailStatusBrush), nameof(DetailPlace), nameof(DetailMove), nameof(DetailDate), nameof(DetailType), nameof(DetailPrice), nameof(DetailRest), nameof(DetailOrg), nameof(DetailScanned) })
            OnChanged(name);
    }

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
}
