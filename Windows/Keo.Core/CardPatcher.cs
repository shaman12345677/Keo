namespace Keo;

public static class CardPatcher
{
    public static string Apply(string xml, IReadOnlyDictionary<string, CardChange> changes, IReadOnlyDictionary<string, Location> locations)
    {
        if (changes.Count == 0) return xml;
        var output = new System.Text.StringBuilder();
        var cursor = 0;
        while (true)
        {
            var open = xml.IndexOf("<MblInventarizovanaKarta", cursor, StringComparison.Ordinal);
            if (open < 0) break;
            output.Append(xml, cursor, open - cursor);
            var close = xml.IndexOf("</MblInventarizovanaKarta>", open, StringComparison.Ordinal);
            if (close < 0) throw new InventoryException("Nepodařilo se přečíst InventarizovaneKarty.xml.");
            close += "</MblInventarizovanaKarta>".Length;
            var card = xml[open..close];
            var id = TopLevelText("id", card) ?? "";
            output.Append(changes.TryGetValue(id, out var change) ? Patch(card, change, locations) : card);
            cursor = close;
        }
        output.Append(xml, cursor, xml.Length - cursor);
        return output.ToString();
    }

    private static string Patch(string card, CardChange change, IReadOnlyDictionary<string, Location> locations)
    {
        var result = SetTopLevelText("stavInventarizace", change.Stav, card);
        result = SetTopLevelText("oskenovano", change.Oskenovano ? "true" : "false", result);
        if (change.NavrhPremisteniId != null)
        {
            if (!locations.TryGetValue(change.NavrhPremisteniId, out var location))
                throw new InventoryException($"Umístění {change.NavrhPremisteniId} v číselníku chybí.");
            result = SetRelocation(location, result);
        }
        else
        {
            result = RemoveTopLevel("navrhPremisteni", result);
        }
        return result;
    }

    private static string SetRelocation(Location location, string card)
    {
        var version = location.Version.Length == 0 ? "0" : location.Version;
        var block = string.Join('\n', new[]
        {
            "<navrhPremisteni>",
            $"      <id>{Escape(location.Id)}</id>",
            $"      <version>{Escape(version)}</version>",
            $"      <kodUtvaru>{Escape(location.KodUtvaru)}</kodUtvaru>",
            $"      <kodMistnosti>{Escape(location.KodMistnosti)}</kodMistnosti>",
            $"      <nazev>{Escape(location.Nazev)}</nazev>",
            "    </navrhPremisteni>"
        });
        if (TopLevelElement("navrhPremisteni", card) is var existing && existing.FullStart >= 0)
            return string.Concat(card.AsSpan(0, existing.FullStart), block, card.AsSpan(existing.FullEnd));
        var close = card.LastIndexOf("</MblInventarizovanaKarta>", StringComparison.Ordinal);
        if (close < 0) return card;
        return string.Concat(card.AsSpan(0, close), "\n    ", block, "\n  </MblInventarizovanaKarta>");
    }

    private static string? TopLevelText(string name, string card)
    {
        var element = TopLevelElement(name, card);
        return element.InnerStart < 0 ? null : card[element.InnerStart..element.InnerEnd];
    }

    private static string SetTopLevelText(string name, string value, string card)
    {
        var element = TopLevelElement(name, card);
        if (element.InnerStart >= 0)
            return string.Concat(card.AsSpan(0, element.InnerStart), Escape(value), card.AsSpan(element.InnerEnd));
        var tag = $"<{name}>{Escape(value)}</{name}>";
        var close = card.LastIndexOf("</MblInventarizovanaKarta>", StringComparison.Ordinal);
        if (close < 0) return card;
        return string.Concat(card.AsSpan(0, close), "    ", tag, "\n  </MblInventarizovanaKarta>");
    }

    private static string RemoveTopLevel(string name, string card)
    {
        var element = TopLevelElement(name, card);
        if (element.FullStart < 0) return card;
        var start = element.FullStart;
        var cursor = start;
        while (cursor > 0)
        {
            var character = card[cursor - 1];
            if (character is ' ' or '\t')
            {
                cursor--;
                continue;
            }
            if (character == '\n')
            {
                cursor--;
                start = cursor;
            }
            break;
        }
        return string.Concat(card.AsSpan(0, start), card.AsSpan(element.FullEnd));
    }

    private readonly record struct Slice(int FullStart, int FullEnd, int InnerStart, int InnerEnd);

    private static Slice TopLevelElement(string name, string card)
    {
        foreach (var item in TopLevelElements(card))
            if (item.Name == name) return item.Slice;
        return new Slice(-1, -1, -1, -1);
    }

    private static List<(string Name, Slice Slice)> TopLevelElements(string card)
    {
        var results = new List<(string, Slice)>();
        var depth = 0;
        var pending = new Stack<(string Name, int Start, int InnerStart)>();
        var index = 0;
        while (index < card.Length)
        {
            if (card[index] != '<')
            {
                index++;
                continue;
            }
            var tag = ReadTag(card, index);
            if (tag == null) break;
            if (tag.Value.IsClose)
            {
                depth--;
                if (depth == 1 && pending.Count > 0)
                {
                    var open = pending.Pop();
                    results.Add((open.Name, new Slice(open.Start, tag.Value.End, open.InnerStart, tag.Value.Start)));
                }
            }
            else if (tag.Value.IsSelfClosing)
            {
                if (depth == 1) results.Add((tag.Value.Name, new Slice(index, tag.Value.End, -1, -1)));
            }
            else
            {
                if (depth == 1) pending.Push((tag.Value.Name, index, tag.Value.End));
                depth++;
            }
            index = tag.Value.End;
        }
        return results;
    }

    private readonly record struct TagScan(string Name, bool IsClose, bool IsSelfClosing, int Start, int End);

    private static TagScan? ReadTag(string text, int start)
    {
        var index = start + 1;
        if (index >= text.Length) return null;
        var isClose = text[index] == '/';
        if (isClose) index++;
        if (index < text.Length && text[index] is '!' or '?')
        {
            var end = text.IndexOf('>', index);
            return end < 0 ? null : new TagScan("", false, false, start, end + 1);
        }
        var nameStart = index;
        while (index < text.Length && (char.IsLetterOrDigit(text[index]) || text[index] is '_' or '-' or ':')) index++;
        var name = text[nameStart..index];
        char? quote = null;
        while (index < text.Length)
        {
            var character = text[index];
            if (quote != null)
            {
                if (character == quote) quote = null;
                index++;
                continue;
            }
            if (character is '"' or '\'')
            {
                quote = character;
                index++;
                continue;
            }
            if (character == '>')
            {
                var selfClosing = !isClose && index > start && text[index - 1] == '/';
                return new TagScan(name, isClose, selfClosing, start, index + 1);
            }
            index++;
        }
        return null;
    }

    private static string Escape(string value) =>
        value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");
}
