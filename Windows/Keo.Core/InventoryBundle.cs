using System.Globalization;
using System.Text;

namespace Keo;

public sealed class InventoryBundle
{
    public required string Filename { get; init; }
    public required List<ZipEntry> Entries { get; init; }
    public required PackageInfo Package { get; init; }
    public required List<AssetCard> Cards { get; init; }
    public required List<Location> Locations { get; init; }
    public required List<FindingCode> Findings { get; init; }

    public static InventoryBundle Load(byte[] data, string filename)
    {
        var entries = ZipArchive.Read(data);
        var cardsEntry = entries.FirstOrDefault(entry => Path.GetFileName(entry.Name) == "InventarizovaneKarty.xml")
            ?? throw new InventoryException("V zipu chybí InventarizovaneKarty.xml.");
        var cards = InventoryXml.ParseCards(cardsEntry.Data);
        if (cards.Count == 0) throw new InventoryException("V zipu chybí InventarizovaneKarty.xml.");
        var locations = entries.FirstOrDefault(entry => Path.GetFileName(entry.Name) == "UtvaryMistnosti.xml") is { } places
            ? InventoryXml.ParseLocations(places.Data)
            : new List<Location>();
        var findings = entries.FirstOrDefault(entry => Path.GetFileName(entry.Name) == "KodyZjisteni.xml") is { } codes
            ? InventoryXml.ParseFindings(codes.Data)
            : new List<FindingCode>();
        var package = entries.FirstOrDefault(entry => Path.GetFileName(entry.Name) == "package-info.xml") is { } info
            ? InventoryXml.ParsePackage(info.Data)
            : new PackageInfo(cards[0].InventuraNazev.Length == 0 ? "Inventura" : cards[0].InventuraNazev, "", "", "");
        return new InventoryBundle
        {
            Filename = filename,
            Entries = entries,
            Package = package,
            Cards = cards,
            Locations = locations,
            Findings = findings
        };
    }

    public byte[] ExportZip(IReadOnlyDictionary<string, CardChange> changes)
    {
        var locationsById = Locations.GroupBy(place => place.Id).ToDictionary(group => group.Key, group => group.Last());
        var index = Entries.FindIndex(entry => Path.GetFileName(entry.Name) == "InventarizovaneKarty.xml");
        if (index < 0) throw new InventoryException("V zipu chybí InventarizovaneKarty.xml.");
        var xml = Encoding.UTF8.GetString(Entries[index].Data);
        xml = CardPatcher.Apply(xml, changes, locationsById);
        var patched = Entries.ToList();
        patched[index] = patched[index] with { Data = Encoding.UTF8.GetBytes(xml) };
        return ZipArchive.Write(patched);
    }

    public InventoryProgress Progress(IReadOnlyDictionary<string, CardChange> changes)
    {
        var result = new InventoryProgress(Cards.Count, 0, 0, 0, 0);
        foreach (var card in Cards)
        {
            switch (CardState.Effective(card, changes.GetValueOrDefault(card.Id)).Stav)
            {
                case "NALEZENO": result.Nalezeno++; break;
                case "PREMISTENI": result.Premisteni++; break;
                case "NENALEZENO": result.Nenalezeno++; break;
                default: result.Ostatni++; break;
            }
        }
        return result;
    }

    public List<LocationGroup> LocationGroups(IReadOnlyDictionary<string, CardChange> changes)
    {
        var buckets = new Dictionary<string, LocationGroup>();
        foreach (var card in Cards)
        {
            var state = CardState.Effective(card, changes.GetValueOrDefault(card.Id));
            var key = card.Umisteni?.Id ?? "";
            if (!buckets.TryGetValue(key, out var group))
            {
                group = new LocationGroup
                {
                    Id = key,
                    Title = card.Umisteni?.Label ?? "Bez umístění",
                    SortKey = card.Umisteni?.KodUtvaru ?? "zzzz"
                };
            }
            group.Total++;
            if (state.Stav is "NALEZENO" or "PREMISTENI") group.Done++;
            buckets[key] = group;
        }
        return buckets.Values
            .OrderBy(group => group.SortKey, StringComparer.Create(CultureInfo.GetCultureInfo("cs-CZ"), ignoreCase: true))
            .ToList();
    }
}

public sealed class InventoryProgress
{
    public InventoryProgress(int total, int nalezeno, int premisteni, int nenalezeno, int ostatni)
    {
        Total = total;
        Nalezeno = nalezeno;
        Premisteni = premisteni;
        Nenalezeno = nenalezeno;
        Ostatni = ostatni;
    }

    public int Total { get; }
    public int Nalezeno { get; set; }
    public int Premisteni { get; set; }
    public int Nenalezeno { get; set; }
    public int Ostatni { get; set; }
    public int Done => Nalezeno + Premisteni + Ostatni;
}

public sealed class LocationGroup
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string SortKey { get; set; } = "";
    public int Total { get; set; }
    public int Done { get; set; }
}
