using System.Globalization;

namespace Keo;

public sealed class InventoryException : Exception
{
    public InventoryException(string message) : base(message) { }
}

public sealed record PackageInfo(string Description, string Date, string DatabaseVersion, string Schema);

public sealed class Location
{
    public string Id { get; set; } = "";
    public string Version { get; set; } = "0";
    public string KodUtvaru { get; set; } = "";
    public string KodMistnosti { get; set; } = "";
    public string Nazev { get; set; } = "";

    public string Label
    {
        get
        {
            var parts = new[] { KodUtvaru, KodMistnosti }.Where(part => part.Length > 0);
            var code = string.Join(" / ", parts);
            if (Nazev.Length == 0) return code.Length == 0 ? "Bez názvu" : code;
            return code.Length == 0 ? Nazev : $"{code} · {Nazev}";
        }
    }

    public Location Clone() => new()
    {
        Id = Id,
        Version = Version,
        KodUtvaru = KodUtvaru,
        KodMistnosti = KodMistnosti,
        Nazev = Nazev
    };
}

public sealed class FindingCode
{
    public string Id { get; set; } = "";
    public string Version { get; set; } = "0";
    public string Kod { get; set; } = "";
    public string Nazev { get; set; } = "";
}

public sealed class AssetCard
{
    public string Id { get; set; } = "";
    public string Version { get; set; } = "0";
    public string InventarniCislo { get; set; } = "";
    public string NazevMajetku { get; set; } = "";
    public string TypMajetku { get; set; } = "";
    public string PodtypMajetku { get; set; } = "";
    public string PorizCenaUcetni { get; set; } = "";
    public string UcetniOpravky { get; set; } = "";
    public string ZustatkovaHodnota { get; set; } = "";
    public string DatumZarazeni { get; set; } = "";
    public Location? Umisteni { get; set; }
    public string? UmisteniReference { get; set; }
    public string VyrazZustCena { get; set; } = "";
    public string? Zivotnost { get; set; }
    public string Organizace { get; set; } = "";
    public string StavInventarizace { get; set; } = "NENALEZENO";
    public bool Vyrizeno { get; set; }
    public bool PremisteniSchvaleno { get; set; }
    public bool Oskenovano { get; set; }
    public string InventuraId { get; set; } = "";
    public string InventuraNazev { get; set; } = "";
    public string? InventuraReference { get; set; }
    public Location? Navrh { get; set; }
    public string? NavrhReference { get; set; }

    public string Cislo => InventarniCislo.Trim();
}

public sealed class CardChange
{
    public string Stav { get; set; } = "";
    public bool Oskenovano { get; set; }
    public string? NavrhPremisteniId { get; set; }

    public static CardChange Nalezeno() => new() { Stav = "NALEZENO", Oskenovano = true };
    public static CardChange Nenalezeno() => new() { Stav = "NENALEZENO", Oskenovano = false };
    public static CardChange Premisteni(string locationId) => new()
    {
        Stav = "PREMISTENI",
        Oskenovano = true,
        NavrhPremisteniId = locationId
    };
}

public readonly record struct EffectiveCard(string Stav, bool Oskenovano, string? NavrhId);

public static class CardState
{
    public static EffectiveCard Effective(AssetCard card, CardChange? change)
    {
        if (change != null) return new EffectiveCard(change.Stav, change.Oskenovano, change.NavrhPremisteniId);
        return new EffectiveCard(card.StavInventarizace, card.Oskenovano, card.Navrh?.Id);
    }

    public static bool MatchesOriginal(CardChange change, AssetCard card)
    {
        var original = Effective(card, null);
        return change.Stav == original.Stav
            && change.Oskenovano == original.Oskenovano
            && change.NavrhPremisteniId == original.NavrhId;
    }

    public static bool ScanKeeps(string stav) => stav is "NALEZENO" or "PREMISTENI";

    public static string Title(string stav) => stav switch
    {
        "NALEZENO" => "Nalezeno",
        "PREMISTENI" => "Přemístění",
        "NENALEZENO" => "Nenalezeno",
        _ => stav
    };
}

public static class Codes
{
    public static string Normalize(string raw) =>
        string.Concat(raw.Trim().Where(ch => ch != ' ')).ToLowerInvariant();
}

public sealed class CodeIndex
{
    private readonly Dictionary<string, List<AssetCard>> byCode = new();

    public CodeIndex(IEnumerable<AssetCard> cards)
    {
        foreach (var card in cards)
        {
            var key = Codes.Normalize(card.InventarniCislo);
            if (key.Length == 0) continue;
            if (!byCode.TryGetValue(key, out var list))
            {
                list = new List<AssetCard>();
                byCode[key] = list;
            }
            list.Add(card);
        }
    }

    public IReadOnlyList<AssetCard> Match(string raw)
    {
        var prefix = MatchLongestPrefix(raw);
        if (prefix.Count > 0) return prefix;
        var leading = MatchLeadingNumber(raw);
        if (leading.Count > 0) return leading;
        var extended = MatchFirstLineExtension(raw);
        if (extended is { Count: > 0 }) return extended;
        foreach (var token in CodeTokens(raw))
        {
            if (!byCode.TryGetValue(token, out var cards) || cards.Count == 0) continue;
            if (IsYear(token) || IsNumberInsideName(token, raw)) continue;
            return cards;
        }
        return Array.Empty<AssetCard>();
    }

    private IReadOnlyList<AssetCard> MatchLeadingNumber(string raw)
    {
        var haystack = new string(raw.ToLowerInvariant().Where(ch => !char.IsWhiteSpace(ch)).ToArray());
        var digits = new string(haystack.TakeWhile(char.IsDigit).ToArray());
        if (digits.Length < 3) return Array.Empty<AssetCard>();
        if (byCode.TryGetValue(digits, out var exact)) return exact;
        return byCode.Where(pair => pair.Key.StartsWith(digits + "-", StringComparison.Ordinal))
            .SelectMany(pair => pair.Value)
            .ToArray();
    }

    private IReadOnlyList<AssetCard>? MatchFirstLineExtension(string raw)
    {
        var line = raw.Split('\n', '\r').Select(Codes.Normalize).FirstOrDefault(part => part.Length > 0) ?? "";
        if (line.Length < 2) return null;
        if (byCode.TryGetValue(line, out var exact)) return exact;
        var extended = byCode.Where(pair => pair.Key.StartsWith(line + "-", StringComparison.Ordinal)).ToArray();
        return extended.Length == 1 ? extended[0].Value : null;
    }

    private static bool IsNumberInsideName(string token, string raw)
    {
        if (token.Length > 3 || !token.All(char.IsDigit)) return false;
        var first = raw.Split('\n', '\r').Select(Codes.Normalize).FirstOrDefault(part => part.Length > 0) ?? "";
        return token != first;
    }

    private static bool IsYear(string code)
    {
        return code.Length == 4 && code.All(char.IsDigit) && int.TryParse(code, out var year) && year is >= 1900 and <= 2099;
    }

    private IReadOnlyList<AssetCard> MatchLongestPrefix(string raw)
    {
        var haystack = new string(raw.ToLowerInvariant().Where(ch => !char.IsWhiteSpace(ch)).ToArray());
        if (haystack.Length <= 1) return Array.Empty<AssetCard>();
        var bestCount = 0;
        List<AssetCard> best = new();
        foreach (var (code, cards) in byCode)
        {
            if (code.Length > bestCount && haystack.StartsWith(code, StringComparison.Ordinal))
            {
                bestCount = code.Length;
                best = cards;
            }
        }
        return best;
    }

    public static IEnumerable<string> CodeTokens(string raw)
    {
        var tokens = new List<string>();
        void Add(string value)
        {
            var token = Codes.Normalize(value);
            if (token.Length == 0 || token == "v:2" || tokens.Contains(token)) return;
            tokens.Add(token);
        }
        Add(raw);
        foreach (var part in raw.Split('\n', '\r', '\t', ';', '|', ',', ' ')) Add(part);
        return tokens;
    }
}

public sealed class LocationIndex
{
    private readonly List<Location> locations;
    private readonly Dictionary<string, List<Location>> byKey = new();
    private readonly Dictionary<string, List<Location>> codeKeys = new();

    public LocationIndex(IEnumerable<Location> places)
    {
        locations = places.ToList();
        foreach (var place in locations)
        {
            Add(place.Id, place, true);
            Add(place.KodUtvaru, place, true);
            if (place.KodMistnosti.Length > 0)
            {
                Add(place.KodMistnosti, place, true);
                Add($"{place.KodUtvaru}/{place.KodMistnosti}", place, true);
                Add($"{place.KodUtvaru}-{place.KodMistnosti}", place, true);
                Add(place.KodUtvaru + place.KodMistnosti, place, true);
            }
            Add(place.Nazev, place, false);
        }
    }

    public IReadOnlyList<Location> Match(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) return Array.Empty<Location>();
        var whole = Codes.Normalize(trimmed);
        if (whole.Length == 0 || whole == "v:2") return Array.Empty<Location>();
        if (byKey.TryGetValue(whole, out var hit) && hit.Count > 0) return Sorted(hit);
        var collapsed = Collapse(trimmed);
        if (collapsed != whole && byKey.TryGetValue(collapsed, out hit) && hit.Count > 0) return Sorted(hit);
        var first = trimmed.Split('\n', '\r').Select(Codes.Normalize).FirstOrDefault(part => part.Length > 0 && part != "v:2") ?? "";
        if (byKey.TryGetValue(first, out hit) && hit.Count > 0) return Sorted(hit);
        var prefixed = LongestCodePrefix(collapsed);
        if (prefixed is { Count: > 0 }) return Sorted(prefixed);
        if (collapsed.All(char.IsDigit) && int.TryParse(collapsed, out var value) && value > 0)
        {
            var numeric = locations.Where(place => CodeEquals(place.KodUtvaru, value) || CodeEquals(place.KodMistnosti, value)).ToList();
            if (numeric.Count > 0) return Sorted(numeric);
        }
        return Array.Empty<Location>();
    }

    private void Add(string key, Location place, bool codesOnly)
    {
        var normalized = Codes.Normalize(key);
        if (normalized.Length == 0) return;
        if (codesOnly)
        {
            AddUnique(codeKeys, normalized, place);
            AddUnique(byKey, normalized, place);
        }
        else if (!codeKeys.ContainsKey(normalized))
        {
            AddUnique(byKey, normalized, place);
        }
    }

    private static void AddUnique(Dictionary<string, List<Location>> target, string key, Location place)
    {
        if (!target.TryGetValue(key, out var list))
        {
            list = new List<Location>();
            target[key] = list;
        }
        if (list.All(item => item.Id != place.Id)) list.Add(place);
    }

    private List<Location>? LongestCodePrefix(string haystack)
    {
        if (haystack.Length <= 1) return null;
        var best = 0;
        List<Location> found = new();
        foreach (var (code, places) in codeKeys)
        {
            if (code.Length >= 2 && code.Length > best && haystack.StartsWith(code, StringComparison.Ordinal))
            {
                best = code.Length;
                found = places;
            }
        }
        if (best == 0) return null;
        var merged = new List<Location>(found);
        foreach (var (code, places) in codeKeys)
        {
            if (code.Length != best || !haystack.StartsWith(code, StringComparison.Ordinal)) continue;
            foreach (var place in places)
                if (merged.All(item => item.Id != place.Id)) merged.Add(place);
        }
        return merged;
    }

    private static string Collapse(string raw) =>
        new(raw.ToLowerInvariant().Where(ch => !char.IsWhiteSpace(ch) && ch != '/' && ch != '-').ToArray());

    private static bool CodeEquals(string code, int value) =>
        code.Length > 0 && code.All(char.IsDigit) && int.TryParse(code, out var number) && number == value;

    private static List<Location> Sorted(IEnumerable<Location> places) =>
        places.GroupBy(place => place.Id).Select(group => group.First()).OrderBy(place => place.Id, StringComparer.Ordinal).ToList();
}

public static class Format
{
    private static readonly CultureInfo Czech = CultureInfo.GetCultureInfo("cs-CZ");

    public static string Date(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) return "—";
        if (trimmed.Length >= 10 && !trimmed.Contains(':') &&
            DateTime.TryParseExact(trimmed[..10], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day))
            return day.ToString("d. M. yyyy", Czech);
        return trimmed.Length >= 10 ? trimmed[..10] : trimmed;
    }

    public static string Money(string raw)
    {
        var normalized = raw.Replace(" ", "").Replace(',', '.');
        if (!double.TryParse(normalized, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return raw;
        return value.ToString("C", Czech);
    }
}
