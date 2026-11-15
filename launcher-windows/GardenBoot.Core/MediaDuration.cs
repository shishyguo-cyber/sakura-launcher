using System.Buffers.Binary;

namespace GardenBoot.Core;

/// <summary>
/// Reads a movie's duration from the ISO base media / QuickTime header (moov → mvhd) without decoding video.
/// Works for mp4, m4v and mov. Returns null when the header is missing or malformed.
/// </summary>
public static class MediaDuration
{
    public static double? Read(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return FindMovieHeader(stream, 0, stream.Length);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    public static double? Read(Stream stream) => FindMovieHeader(stream, 0, stream.Length);

    private static double? FindMovieHeader(Stream stream, long start, long end)
    {
        Span<byte> header = stackalloc byte[16];
        var position = start;
        while (position + 8 <= end)
        {
            stream.Position = position;
            if (!ReadExactly(stream, header[..8])) return null;
            long size = BinaryPrimitives.ReadUInt32BigEndian(header);
            var type = System.Text.Encoding.ASCII.GetString(header.Slice(4, 4));
            var headerLength = 8;
            if (size == 1)
            {
                if (!ReadExactly(stream, header.Slice(8, 8))) return null;
                size = (long)BinaryPrimitives.ReadUInt64BigEndian(header.Slice(8, 8));
                headerLength = 16;
            }
            else if (size == 0) size = end - position;
            if (size < headerLength || position + size > end) return null;
            if (type == "moov") return FindMovieHeader(stream, position + headerLength, position + size);
            if (type == "mvhd") return ParseMovieHeader(stream, position + headerLength, size - headerLength);
            position += size;
        }
        return null;
    }

    private static double? ParseMovieHeader(Stream stream, long position, long length)
    {
        Span<byte> body = stackalloc byte[32];
        if (length < 20) return null;
        stream.Position = position;
        if (!ReadExactly(stream, body[..(int)Math.Min(32, length)])) return null;
        var version = body[0];
        ulong timescale, duration;
        if (version == 1)
        {
            if (length < 32) return null;
            timescale = BinaryPrimitives.ReadUInt32BigEndian(body.Slice(20, 4));
            duration = BinaryPrimitives.ReadUInt64BigEndian(body.Slice(24, 8));
        }
        else
        {
            timescale = BinaryPrimitives.ReadUInt32BigEndian(body.Slice(12, 4));
            duration = BinaryPrimitives.ReadUInt32BigEndian(body.Slice(16, 4));
        }
        if (timescale == 0 || duration == ulong.MaxValue || duration == uint.MaxValue && version == 0) return null;
        return duration / (double)timescale;
    }

    private static bool ReadExactly(Stream stream, Span<byte> buffer)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var n = stream.Read(buffer[read..]);
            if (n == 0) return false;
            read += n;
        }
        return true;
    }
}
