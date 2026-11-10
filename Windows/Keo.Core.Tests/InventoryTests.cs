using Keo;
using Xunit;

namespace Keo.Tests;

public class InventoryTests
{
    [Fact]
    public void ZipRoundTripKeepsDatesAndRelocation()
    {
        var xml = """
        <list>
          <MblInventarizovanaKarta>
            <id>1</id>
            <version>0</version>
            <inventarniCislo>  10-A</inventarniCislo>
            <nazevMajetku>Stůl</nazevMajetku>
            <datumZarazeni class="sql-date">2020-05-01</datumZarazeni>
            <umisteni>
              <id>L1</id>
              <version>2</version>
              <kodUtvaru>A</kodUtvaru>
              <kodMistnosti></kodMistnosti>
              <nazev>Dílna &amp; sklad</nazev>
            </umisteni>
            <stavInventarizace>NENALEZENO</stavInventarizace>
            <oskenovano>false</oskenovano>
            <inventura>
              <id>9</id>
              <version>0</version>
              <nazev>Inventura</nazev>
            </inventura>
          </MblInventarizovanaKarta>
          <MblInventarizovanaKarta>
            <id>2</id>
            <version>0</version>
            <inventarniCislo>11-A</inventarniCislo>
            <nazevMajetku>Židle</nazevMajetku>
            <datumZarazeni class="sql-date">2020-05-01</datumZarazeni>
            <umisteni reference="../../MblInventarizovanaKarta/umisteni"/>
            <stavInventarizace>NENALEZENO</stavInventarizace>
            <oskenovano>false</oskenovano>
            <inventura reference="../../MblInventarizovanaKarta/inventura"/>
          </MblInventarizovanaKarta>
        </list>
        """;
        var locations = """
        <list>
          <MblUtvaryMistnosti>
            <id>L1</id>
            <version>2</version>
            <kodUtvaru>A</kodUtvaru>
            <kodMistnosti></kodMistnosti>
            <nazev>Dílna &amp; sklad</nazev>
          </MblUtvaryMistnosti>
          <MblUtvaryMistnosti>
            <id>L2</id>
            <version>0</version>
            <kodUtvaru>B</kodUtvaru>
            <kodMistnosti>3</kodMistnosti>
            <nazev>Sborovna</nazev>
          </MblUtvaryMistnosti>
        </list>
        """;
        var info = """
        <package-info>
          <description>Inventura</description>
          <date>2020-05-01 08:00:00</date>
          <databaseVersion>21</databaseVersion>
          <schema>skola</schema>
        </package-info>
        """;
        var zip = ZipArchive.Write(new[]
        {
            new ZipEntry("info/package-info.xml", System.Text.Encoding.UTF8.GetBytes(info)),
            new ZipEntry("InventarizovaneKarty.xml", System.Text.Encoding.UTF8.GetBytes(xml)),
            new ZipEntry("UtvaryMistnosti.xml", System.Text.Encoding.UTF8.GetBytes(locations))
        });
        var bundle = InventoryBundle.Load(zip, "Inventura.zip");
        Assert.Equal(2, bundle.Cards.Count);
        Assert.Equal("10-A", bundle.Cards[0].Cislo);
        Assert.Equal("  10-A", bundle.Cards[0].InventarniCislo);
        Assert.Equal("2020-05-01", bundle.Cards[0].DatumZarazeni);
        Assert.Equal("Dílna & sklad", bundle.Cards[1].Umisteni?.Nazev);
        Assert.Equal("Inventura", bundle.Cards[1].InventuraNazev);
        Assert.Equal("21", bundle.Package.DatabaseVersion);
        Assert.Equal(2, bundle.Locations.Count);

        var index = new CodeIndex(bundle.Cards);
        Assert.Equal("1", Assert.Single(index.Match("10-A")).Id);
        Assert.Equal("1", Assert.Single(index.Match("10-A|Stůl|2020-05-01|V:2")).Id);
        Assert.Empty(index.Match("V:2"));
        Assert.Empty(index.Match("110-A"));

        var photo = new CardPhoto
        {
            CardID = "1",
            LocalID = 1,
            FileName = "karta_1_20260101_120000.jpg",
            JpegData = new byte[] { 0xFF, 0xD8, 0xFF, 0xD9 },
            ThumbJpegData = new byte[] { 0xFF, 0xD8, 0xFF, 0xD9 }
        };
        var exported = bundle.ExportZip(new Dictionary<string, CardChange>
        {
            ["1"] = CardChange.Nalezeno(),
            ["2"] = CardChange.Premisteni("L2")
        }, new[] { photo });
        var again = InventoryBundle.Load(exported, "export.zip");
        Assert.Equal("NALEZENO", again.Cards[0].StavInventarizace);
        Assert.True(again.Cards[0].Oskenovano);
        Assert.Null(again.Cards[0].Navrh);
        Assert.Equal("2020-05-01", again.Cards[0].DatumZarazeni);
        Assert.Equal("  10-A", again.Cards[0].InventarniCislo);
        Assert.Equal("PREMISTENI", again.Cards[1].StavInventarizace);
        Assert.Equal("L2", again.Cards[1].Navrh?.Id);
        Assert.Equal("Sborovna", again.Cards[1].Navrh?.Nazev);
        Assert.Equal("Dílna & sklad", again.Cards[1].Umisteni?.Nazev);
        var raw = System.Text.Encoding.UTF8.GetString(again.Entries.First(entry => entry.Name == "InventarizovaneKarty.xml").Data);
        Assert.Contains("class=\"sql-date\"", raw);
        Assert.Contains("<stavInventarizace>PREMISTENI</stavInventarizace>", raw);
        Assert.Contains(again.Entries, entry => entry.Name == "photos/karta_1_20260101_120000.jpg");
        Assert.Contains(again.Entries, entry => entry.Name == "photos/index.csv");
        var fotky = System.Text.Encoding.UTF8.GetString(again.Entries.First(entry => entry.Name == "FotkyInventarizovaneKarty.xml").Data);
        Assert.Contains("MblFotkaInventarizovaneKarty", fotky);
        Assert.Contains("photos/karta_1_20260101_120000.jpg", fotky);
    }

    [Fact]
    public void GluedLabelUsesLongestNumber()
    {
        AssetCard Card(string id, string number)
        {
            var card = new AssetCard { Id = id, InventarniCislo = number };
            return card;
        }
        var index = new CodeIndex(new[]
        {
            Card("short", "1550"),
            Card("full", "1550-POD")
        });
        Assert.Empty(index.Match("k01.01.2019V:2"));
        Assert.Equal("full", Assert.Single(index.Match("1550-POD\nNázev k\n01.01.2019\nV:2")).Id);
    }

    [Fact]
    public void SampleInventoryLoads()
    {
        var path = FindSample();
        var bundle = InventoryBundle.Load(File.ReadAllBytes(path), "Inventura.zip");
        Assert.Equal(17, bundle.Cards.Count);
        var moved = bundle.Cards.Single(card => card.Id == "7");
        Assert.Equal("PREMISTENI", moved.StavInventarizace);
        Assert.Equal("L3", moved.Navrh?.Id);
        Assert.Equal("1022", Assert.Single(new CodeIndex(bundle.Cards).Match("1022\nTiskárna\n14.04.2020\nV:2")).Cislo);
        Assert.True(CardState.ScanKeeps("PREMISTENI"));
        Assert.False(CardState.ScanKeeps("NENALEZENO"));
    }

    [Fact]
    public void SlowGapInsideLabelStaysOneScan()
    {
        var assembler = new ScanBurstAssembler { Idle = 1.2 };
        var time = 10.0;
        foreach (var character in "1550-POD")
        {
            assembler.PushForced(character, time);
            time += 0.05;
        }
        assembler.PushTerminator(time);
        time += 0.8;
        foreach (var character in "Nazev k")
        {
            var steps = assembler.PushForced(character, time);
            Assert.DoesNotContain(steps, step => step.Kind is ScanBurstKind.Commit or ScanBurstKind.CommitIdle);
            time += 0.05;
        }
        time += 0.8;
        assembler.PushTerminator(time);
        time += 1.3;
        var done = assembler.Tick(time);
        Assert.Contains(done, step => step.Kind == ScanBurstKind.CommitIdle && step.Text.Contains("1550-POD"));
    }

    private static string FindSample()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            var candidate = Path.Combine(dir.FullName, "Vzor", "Inventura.zip");
            if (File.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }
        throw new FileNotFoundException("Vzor/Inventura.zip");
    }
}
