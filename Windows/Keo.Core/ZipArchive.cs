using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace Keo;

public sealed record ZipEntry(string Name, byte[] Data);

public static class ZipArchive
{
    public static List<ZipEntry> Read(byte[] data)
    {
        var eocd = FindEocd(data) ?? throw new InventoryException("Soubor není zip s inventurou.");
        var count = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(eocd + 10));
        var directory = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(eocd + 16));
        var cursor = directory;
        var entries = new List<ZipEntry>(count);
        for (var i = 0; i < count; i++)
        {
            if (cursor + 46 > data.Length || BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(cursor)) != 0x02014b50)
                throw new InventoryException("Zip nejde přečíst (centrální adresář).");
            var method = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(cursor + 10));
            var crc = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(cursor + 16));
            var compressedSize = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(cursor + 20));
            var uncompressedSize = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(cursor + 24));
            var nameLength = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(cursor + 28));
            var extraLength = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(cursor + 30));
            var commentLength = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(cursor + 32));
            var localOffset = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(cursor + 42));
            var nameStart = cursor + 46;
            var nameEnd = nameStart + nameLength;
            if (nameEnd + extraLength + commentLength > data.Length)
                throw new InventoryException("Zip nejde přečíst (název položky).");
            var name = Encoding.UTF8.GetString(data, nameStart, nameLength);
            cursor = nameEnd + extraLength + commentLength;
            if (name.EndsWith('/')) continue;
            if (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff)
                throw new InventoryException("Zip nejde přečíst (zip64 není podporovaný).");
            var payload = ReadLocal(data, localOffset, (int)compressedSize, (int)uncompressedSize, method, crc);
            entries.Add(new ZipEntry(name, payload));
        }
        return entries;
    }

    public static byte[] Write(IReadOnlyList<ZipEntry> entries, DateTime? date = null)
    {
        var (time, day) = DosDateTime(date ?? DateTime.Now);
        using var locals = new MemoryStream();
        using var central = new MemoryStream();
        foreach (var entry in entries)
        {
            var name = Encoding.UTF8.GetBytes(entry.Name);
            if (name.Length > ushort.MaxValue) throw new InventoryException("Zip nejde přečíst (příliš dlouhý název).");
            var crc = Crc32(entry.Data);
            var compressed = Deflate(entry.Data);
            var store = compressed.Length >= entry.Data.Length;
            var payload = store ? entry.Data : compressed;
            ushort method = store ? (ushort)0 : (ushort)8;
            var offset = (uint)locals.Length;
            WriteLocal(locals, name, method, time, day, crc, (uint)payload.Length, (uint)entry.Data.Length);
            locals.Write(payload);
            WriteCentral(central, name, method, time, day, crc, (uint)payload.Length, (uint)entry.Data.Length, offset);
        }
        var directoryOffset = (uint)locals.Length;
        using var result = new MemoryStream();
        locals.Position = 0;
        locals.CopyTo(result);
        central.Position = 0;
        central.CopyTo(result);
        Span<byte> eocd = stackalloc byte[22];
        BinaryPrimitives.WriteUInt32LittleEndian(eocd, 0x06054b50);
        BinaryPrimitives.WriteUInt16LittleEndian(eocd[8..], (ushort)entries.Count);
        BinaryPrimitives.WriteUInt16LittleEndian(eocd[10..], (ushort)entries.Count);
        BinaryPrimitives.WriteUInt32LittleEndian(eocd[12..], (uint)central.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(eocd[16..], directoryOffset);
        result.Write(eocd);
        return result.ToArray();
    }

    private static byte[] ReadLocal(byte[] data, int offset, int compressedSize, int uncompressedSize, ushort method, uint crc)
    {
        if (offset + 30 > data.Length || BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(offset)) != 0x04034b50)
            throw new InventoryException("Zip nejde přečíst (lokální hlavička).");
        var nameLength = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(offset + 26));
        var extraLength = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(offset + 28));
        var start = offset + 30 + nameLength + extraLength;
        var end = start + compressedSize;
        if (start < 0 || end > data.Length) throw new InventoryException("Zip nejde přečíst (data položky).");
        var compressed = data.AsSpan(start, compressedSize);
        byte[] output = method switch
        {
            0 => compressed.ToArray(),
            8 => uncompressedSize == 0 ? Array.Empty<byte>() : Inflate(compressed, uncompressedSize),
            _ => throw new InventoryException($"Zip nejde přečíst (komprese {method}).")
        };
        if (crc != 0 && Crc32(output) != crc) throw new InventoryException("Zip nejde přečíst (kontrolní součet).");
        return output;
    }

    private static byte[] Inflate(ReadOnlySpan<byte> data, int uncompressedSize)
    {
        using var input = new MemoryStream(data.ToArray());
        using var deflate = new DeflateStream(input, CompressionMode.Decompress);
        var output = new byte[uncompressedSize];
        var read = 0;
        while (read < uncompressedSize)
        {
            var n = deflate.Read(output, read, uncompressedSize - read);
            if (n == 0) break;
            read += n;
        }
        if (read != uncompressedSize) throw new InventoryException("Zip nejde přečíst (inflate).");
        return output;
    }

    private static byte[] Deflate(byte[] data)
    {
        if (data.Length == 0) return Array.Empty<byte>();
        using var output = new MemoryStream();
        using (var deflate = new DeflateStream(output, CompressionLevel.Optimal, leaveOpen: true))
            deflate.Write(data);
        return output.ToArray();
    }

    private static void WriteLocal(Stream stream, byte[] name, ushort method, ushort time, ushort day, uint crc, uint compressed, uint uncompressed)
    {
        Span<byte> header = stackalloc byte[30];
        BinaryPrimitives.WriteUInt32LittleEndian(header, 0x04034b50);
        BinaryPrimitives.WriteUInt16LittleEndian(header[4..], 20);
        BinaryPrimitives.WriteUInt16LittleEndian(header[6..], 0x0800);
        BinaryPrimitives.WriteUInt16LittleEndian(header[8..], method);
        BinaryPrimitives.WriteUInt16LittleEndian(header[10..], time);
        BinaryPrimitives.WriteUInt16LittleEndian(header[12..], day);
        BinaryPrimitives.WriteUInt32LittleEndian(header[14..], crc);
        BinaryPrimitives.WriteUInt32LittleEndian(header[18..], compressed);
        BinaryPrimitives.WriteUInt32LittleEndian(header[22..], uncompressed);
        BinaryPrimitives.WriteUInt16LittleEndian(header[26..], (ushort)name.Length);
        stream.Write(header);
        stream.Write(name);
    }

    private static void WriteCentral(Stream stream, byte[] name, ushort method, ushort time, ushort day, uint crc, uint compressed, uint uncompressed, uint offset)
    {
        Span<byte> header = stackalloc byte[46];
        BinaryPrimitives.WriteUInt32LittleEndian(header, 0x02014b50);
        BinaryPrimitives.WriteUInt16LittleEndian(header[4..], 20);
        BinaryPrimitives.WriteUInt16LittleEndian(header[6..], 20);
        BinaryPrimitives.WriteUInt16LittleEndian(header[8..], 0x0800);
        BinaryPrimitives.WriteUInt16LittleEndian(header[10..], method);
        BinaryPrimitives.WriteUInt16LittleEndian(header[12..], time);
        BinaryPrimitives.WriteUInt16LittleEndian(header[14..], day);
        BinaryPrimitives.WriteUInt32LittleEndian(header[16..], crc);
        BinaryPrimitives.WriteUInt32LittleEndian(header[20..], compressed);
        BinaryPrimitives.WriteUInt32LittleEndian(header[24..], uncompressed);
        BinaryPrimitives.WriteUInt16LittleEndian(header[28..], (ushort)name.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(header[42..], offset);
        stream.Write(header);
        stream.Write(name);
    }

    public static uint Crc32(ReadOnlySpan<byte> data)
    {
        var crc = 0xffffffffu;
        foreach (var value in data)
        {
            crc ^= value;
            for (var i = 0; i < 8; i++)
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320u : crc >> 1;
        }
        return ~crc;
    }

    private static int? FindEocd(byte[] data)
    {
        if (data.Length < 22) return null;
        var lower = Math.Max(0, data.Length - 22 - 65535);
        for (var index = data.Length - 22; index >= lower; index--)
        {
            if (BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(index)) == 0x06054b50)
            {
                var comment = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(index + 20));
                if (index + 22 + comment == data.Length) return index;
            }
            if (index == 0) break;
        }
        return null;
    }

    private static (ushort Time, ushort Day) DosDateTime(DateTime date)
    {
        var local = date.Kind == DateTimeKind.Utc ? date.ToLocalTime() : date;
        var year = (ushort)Math.Max(0, local.Year - 1980);
        var time = (ushort)((local.Hour << 11) | (local.Minute << 5) | (local.Second / 2));
        var day = (ushort)((year << 9) | (local.Month << 5) | local.Day);
        return (time, day);
    }
}
