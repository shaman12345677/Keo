using System.Xml;

namespace Keo;

public static class InventoryXml
{
    public static PackageInfo ParsePackage(byte[] data)
    {
        var parser = new NodeParser();
        parser.Parse(data, "package-info.xml");
        return parser.Package;
    }

    public static List<AssetCard> ParseCards(byte[] data)
    {
        var parser = new NodeParser();
        parser.Parse(data, "InventarizovaneKarty.xml");
        ResolveReferences(parser.Cards);
        return parser.Cards;
    }

    public static List<Location> ParseLocations(byte[] data)
    {
        var parser = new NodeParser();
        parser.Parse(data, "UtvaryMistnosti.xml");
        return parser.Locations;
    }

    public static List<FindingCode> ParseFindings(byte[] data)
    {
        var parser = new NodeParser();
        parser.Parse(data, "KodyZjisteni.xml");
        return parser.Findings;
    }

    private static void ResolveReferences(List<AssetCard> cards)
    {
        for (var index = 0; index < cards.Count; index++)
        {
            var card = cards[index];
            if (card.Umisteni == null && card.UmisteniReference != null)
                card.Umisteni = LocationAt(card.UmisteniReference, cards, new HashSet<string>());
            if (card.Navrh == null && card.NavrhReference != null)
                card.Navrh = LocationAt(card.NavrhReference, cards, new HashSet<string>());
            if (card.InventuraId.Length == 0 && card.InventuraReference != null)
            {
                var found = InventoryAt(card.InventuraReference, cards, new HashSet<string>());
                if (found != null)
                {
                    card.InventuraId = found.Value.Id;
                    card.InventuraNazev = found.Value.Name;
                }
            }
        }
    }

    private static Location? LocationAt(string path, List<AssetCard> cards, HashSet<string> visiting)
    {
        var target = XStreamTarget(path);
        if (!visiting.Add(path) || target == null || target.Value.Index < 0 || target.Value.Index >= cards.Count)
            return null;
        var card = cards[target.Value.Index];
        return target.Value.Field switch
        {
            "umisteni" => card.Umisteni ?? (card.UmisteniReference == null ? null : LocationAt(card.UmisteniReference, cards, visiting)),
            "navrhPremisteni" => card.Navrh ?? (card.NavrhReference == null ? null : LocationAt(card.NavrhReference, cards, visiting)),
            _ => null
        };
    }

    private static (string Id, string Name)? InventoryAt(string path, List<AssetCard> cards, HashSet<string> visiting)
    {
        var target = XStreamTarget(path);
        if (!visiting.Add(path) || target == null || target.Value.Index < 0 || target.Value.Index >= cards.Count)
            return null;
        var card = cards[target.Value.Index];
        if (card.InventuraId.Length > 0) return (card.InventuraId, card.InventuraNazev);
        return card.InventuraReference == null ? null : InventoryAt(card.InventuraReference, cards, visiting);
    }

    private static (int Index, string Field)? XStreamTarget(string path)
    {
        var marker = path.IndexOf("MblInventarizovanaKarta", StringComparison.Ordinal);
        if (marker < 0) return null;
        var rest = path[(marker + "MblInventarizovanaKarta".Length)..];
        var index = 0;
        if (rest.StartsWith('['))
        {
            rest = rest[1..];
            var digits = new string(rest.TakeWhile(char.IsDigit).ToArray());
            index = (int.TryParse(digits, out var number) ? number : 1) - 1;
            rest = rest[digits.Length..];
            if (rest.StartsWith(']')) rest = rest[1..];
        }
        if (rest.StartsWith('/')) rest = rest[1..];
        return rest.Length == 0 ? null : (index, rest);
    }
}

sealed class NodeParser
{
    public PackageInfo Package { get; private set; } = new("", "", "", "");
    public List<AssetCard> Cards { get; } = new();
    public List<Location> Locations { get; } = new();
    public List<FindingCode> Findings { get; } = new();

    private readonly List<string> stack = new();
    private string text = "";
    private AssetCard? card;
    private Location? listLocation;
    private Location? nestedLocation;
    private string? nestedKey;
    private FindingCode? finding;

    public void Parse(byte[] data, string label)
    {
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(data), new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit,
                IgnoreWhitespace = false,
                IgnoreComments = true
            });
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element)
                {
                    var empty = reader.IsEmptyElement;
                    Start(reader);
                    if (empty) End(reader.LocalName);
                }
                else if (reader.NodeType is XmlNodeType.Text or XmlNodeType.CDATA)
                {
                    text += reader.Value;
                }
                else if (reader.NodeType == XmlNodeType.EndElement)
                {
                    End(reader.LocalName);
                }
            }
        }
        catch (XmlException)
        {
            throw new InventoryException($"Nepodařilo se přečíst {label}.");
        }
    }

    private void Start(XmlReader reader)
    {
        text = "";
        var parent = stack.Count == 0 ? null : stack[^1];
        var name = reader.LocalName;
        stack.Add(name);
        switch (name)
        {
            case "MblInventarizovanaKarta":
                card = new AssetCard();
                break;
            case "MblUtvaryMistnosti":
                listLocation = new Location();
                break;
            case "MblKodZjisteni":
                finding = new FindingCode();
                break;
            case "umisteni" or "navrhPremisteni" when parent == "MblInventarizovanaKarta":
                var reference = reader.GetAttribute("reference");
                if (reference != null)
                {
                    if (name == "umisteni") card!.UmisteniReference = reference;
                    else card!.NavrhReference = reference;
                }
                else
                {
                    nestedLocation = new Location();
                    nestedKey = name;
                }
                break;
            case "inventura":
                var inventoryReference = reader.GetAttribute("reference");
                if (inventoryReference != null && card != null) card.InventuraReference = inventoryReference;
                break;
        }
    }

    private void End(string name)
    {
        var parent = stack.Count >= 2 ? stack[^2] : null;
        var value = text;
        switch (name)
        {
            case "MblInventarizovanaKarta":
                if (card != null) Cards.Add(card);
                card = null;
                break;
            case "MblUtvaryMistnosti":
                if (listLocation != null) Locations.Add(listLocation);
                listLocation = null;
                break;
            case "MblKodZjisteni":
                if (finding != null) Findings.Add(finding);
                finding = null;
                break;
            case "umisteni" or "navrhPremisteni":
                if (nestedKey == name && nestedLocation != null && card != null)
                {
                    if (name == "umisteni") card.Umisteni = nestedLocation;
                    else card.Navrh = nestedLocation;
                }
                nestedLocation = null;
                nestedKey = null;
                break;
            default:
                Apply(name, parent, value);
                break;
        }
        if (stack.Count > 0) stack.RemoveAt(stack.Count - 1);
        text = "";
    }

    private void Apply(string name, string? parent, string value)
    {
        var trimmed = value.Trim();
        switch (parent)
        {
            case "package-info":
                Package = name switch
                {
                    "description" => Package with { Description = trimmed },
                    "date" => Package with { Date = trimmed },
                    "databaseVersion" => Package with { DatabaseVersion = trimmed },
                    "schema" => Package with { Schema = trimmed },
                    _ => Package
                };
                break;
            case "MblInventarizovanaKarta" when card != null:
                switch (name)
                {
                    case "id": card.Id = trimmed; break;
                    case "version": card.Version = trimmed; break;
                    case "inventarniCislo": card.InventarniCislo = value.Replace("\n", "").Replace("\r", ""); break;
                    case "nazevMajetku": card.NazevMajetku = trimmed; break;
                    case "typMajetku": card.TypMajetku = trimmed; break;
                    case "podtypMajetku": card.PodtypMajetku = trimmed; break;
                    case "porizCenaUcetni": card.PorizCenaUcetni = trimmed; break;
                    case "ucetniOpravky": card.UcetniOpravky = trimmed; break;
                    case "zustatkovaHodnota": card.ZustatkovaHodnota = trimmed; break;
                    case "datumZarazeni": card.DatumZarazeni = trimmed; break;
                    case "vyrazZustCena": card.VyrazZustCena = trimmed; break;
                    case "zivotnost": card.Zivotnost = trimmed; break;
                    case "organizace": card.Organizace = trimmed; break;
                    case "stavInventarizace": card.StavInventarizace = trimmed; break;
                    case "vyrizeno": card.Vyrizeno = trimmed == "true"; break;
                    case "premisteniSchvaleno": card.PremisteniSchvaleno = trimmed == "true"; break;
                    case "oskenovano": card.Oskenovano = trimmed == "true"; break;
                }
                break;
            case "inventura" when card != null:
                if (name == "id") card.InventuraId = trimmed;
                else if (name == "nazev") card.InventuraNazev = trimmed;
                break;
            case "umisteni" or "navrhPremisteni" when nestedLocation != null:
                SetLocation(name, trimmed, nestedLocation);
                break;
            case "MblUtvaryMistnosti" when listLocation != null:
                SetLocation(name, trimmed, listLocation);
                break;
            case "MblKodZjisteni" when finding != null:
                switch (name)
                {
                    case "id": finding.Id = trimmed; break;
                    case "version": finding.Version = trimmed; break;
                    case "kod": finding.Kod = trimmed; break;
                    case "nazev": finding.Nazev = trimmed; break;
                }
                break;
        }
    }

    private static void SetLocation(string name, string value, Location location)
    {
        switch (name)
        {
            case "id": location.Id = value; break;
            case "version": location.Version = value; break;
            case "kodUtvaru": location.KodUtvaru = value; break;
            case "kodMistnosti": location.KodMistnosti = value; break;
            case "nazev": location.Nazev = value; break;
        }
    }
}
