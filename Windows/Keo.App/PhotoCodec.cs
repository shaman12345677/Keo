using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.Versioning;

namespace Keo;

/// <summary>JPEG pro inventuru: max. 1280 px, thumb 150 px, bez EXIF orientation.</summary>
[SupportedOSPlatform("windows")]
public static class PhotoCodec
{
    public static (byte[] Full, byte[] Thumb)? PrepareInventoryJpeg(byte[] data, int maxSide = 1280, long quality = 72L)
    {
        try
        {
            using var input = new MemoryStream(data);
            using var source = Image.FromStream(input, useEmbeddedColorManagement: false, validateImageData: false);
            ApplyExifOrientation(source);
            using var full = Resize(source, maxSide);
            using var thumb = Resize(source, 150);
            var fullBytes = EncodeJpeg(full, quality);
            var thumbBytes = EncodeJpeg(thumb, 70L);
            return fullBytes == null || thumbBytes == null ? null : (fullBytes, thumbBytes);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static Bitmap Resize(Image source, int maxSide)
    {
        var scale = Math.Min(1.0, maxSide / (double)Math.Max(source.Width, source.Height));
        var width = Math.Max(1, (int)Math.Round(source.Width * scale));
        var height = Math.Max(1, (int)Math.Round(source.Height * scale));
        var bitmap = new Bitmap(width, height);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.CompositingMode = CompositingMode.SourceCopy;
        graphics.CompositingQuality = CompositingQuality.HighQuality;
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.SmoothingMode = SmoothingMode.HighQuality;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.DrawImage(source, 0, 0, width, height);
        return bitmap;
    }

    private static byte[]? EncodeJpeg(Image image, long quality)
    {
        var codec = ImageCodecInfo.GetImageEncoders().FirstOrDefault(item => item.FormatID == ImageFormat.Jpeg.Guid);
        if (codec == null) return null;
        using var stream = new MemoryStream();
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(Encoder.Quality, quality);
        image.Save(stream, codec, parameters);
        return stream.ToArray();
    }

    private static void ApplyExifOrientation(Image image)
    {
        const int orientationId = 0x0112;
        if (!image.PropertyIdList.Contains(orientationId)) return;
        var value = image.GetPropertyItem(orientationId)?.Value;
        if (value == null || value.Length == 0) return;
        switch (value[0])
        {
            case 2: image.RotateFlip(RotateFlipType.RotateNoneFlipX); break;
            case 3: image.RotateFlip(RotateFlipType.Rotate180FlipNone); break;
            case 4: image.RotateFlip(RotateFlipType.Rotate180FlipX); break;
            case 5: image.RotateFlip(RotateFlipType.Rotate90FlipX); break;
            case 6: image.RotateFlip(RotateFlipType.Rotate90FlipNone); break;
            case 7: image.RotateFlip(RotateFlipType.Rotate270FlipX); break;
            case 8: image.RotateFlip(RotateFlipType.Rotate270FlipNone); break;
        }
        try { image.RemovePropertyItem(orientationId); } catch (Exception) { /* ignore */ }
    }
}
