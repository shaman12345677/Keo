using System.Globalization;
using System.Text;

namespace Keo;

public sealed class CardPhoto
{
    public required string CardID { get; init; }
    public required int LocalID { get; init; }
    public required string FileName { get; init; }
    public required byte[] JpegData { get; init; }
    public required byte[] ThumbJpegData { get; init; }
    public string ZipPath => $"photos/{FileName}";
}

public static class CardPhotoExport
{
    public static string MakeFileName(int localID, DateTime? date = null)
    {
        var stamp = (date ?? DateTime.Now).ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture);
        return $"karta_{localID}_{stamp}.jpg";
    }

    public static byte[] MakeIndexCsv(IEnumerable<CardPhoto> photos)
    {
        var lines = new List<string> { "foto_android_id;karta_android_id;zip_path" };
        foreach (var photo in photos)
            lines.Add($"{photo.LocalID};{photo.LocalID};{photo.ZipPath}");
        return Encoding.UTF8.GetBytes(string.Join("\n", lines) + "\n");
    }

    public static byte[] MakeFotkyXml(IEnumerable<CardPhoto> photos)
    {
        var body = new StringBuilder();
        body.Append("<list>\n");
        foreach (var photo in photos)
        {
            var base64 = Convert.ToBase64String(photo.ThumbJpegData);
            body.Append($"""
              <MblFotkaInventarizovaneKarty>
                <id>0</id>
                <version>0</version>
                <base64Data>{base64}</base64Data>
                <inventarizovanaKarta>
                  <id>{Escape(photo.CardID)}</id>
                  <version>0</version>
                  <hiden>false</hiden>
                  <oskenovano>false</oskenovano>
                  <porizCenaUcetni>0</porizCenaUcetni>
                  <premisteniSchvaleno>false</premisteniSchvaleno>
                  <ucetniOpravky>0</ucetniOpravky>
                  <vyrizeno>false</vyrizeno>
                  <zustatkovaHodnota>0</zustatkovaHodnota>
                </inventarizovanaKarta>
                <nazev>{Escape(photo.FileName)}</nazev>
                <zipPath>{Escape(photo.ZipPath)}</zipPath>
              </MblFotkaInventarizovaneKarty>

            """);
        }
        body.Append("</list>");
        return Encoding.UTF8.GetBytes(body.ToString());
    }

    private static string Escape(string value) =>
        value.Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal)
            .Replace("\"", "&quot;", StringComparison.Ordinal);
}
