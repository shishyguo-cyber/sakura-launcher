using System.Buffers.Binary;

namespace GardenBoot.Core.Tests;

public static class MediaDurationTests
{
    private static byte[] Box(string type, byte[] body, bool large = false)
    {
        var header = large ? 16 : 8;
        var box = new byte[header + body.Length];
        if (large) { BinaryPrimitives.WriteUInt32BigEndian(box, 1); BinaryPrimitives.WriteUInt64BigEndian(box.AsSpan(8), (ulong)box.Length); }
        else BinaryPrimitives.WriteUInt32BigEndian(box, (uint)box.Length);
        System.Text.Encoding.ASCII.GetBytes(type).CopyTo(box, 4);
        body.CopyTo(box, header);
        return box;
    }

    private static byte[] MovieHeader(int version, uint timescale, ulong duration)
    {
        var body = new byte[version == 1 ? 112 : 100];
        body[0] = (byte)version;
        if (version == 1) { BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(20), timescale); BinaryPrimitives.WriteUInt64BigEndian(body.AsSpan(24), duration); }
        else { BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(12), timescale); BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(16), (uint)duration); }
        return Box("mvhd", body);
    }

    private static double? Read(params byte[][] boxes) => MediaDuration.Read(new MemoryStream(boxes.SelectMany(b => b).ToArray()));

    [Test]
    public static void ReadsVersion0And1AndSkipsOtherBoxes()
    {
        Check.Near(4.5, Read(Box("ftyp", new byte[8]), Box("mdat", new byte[64]), Box("moov", MovieHeader(0, 600, 2700)))!.Value);
        Check.Near(12.25, Read(Box("ftyp", new byte[8]), Box("moov", MovieHeader(1, 1000, 12250)))!.Value);
        Check.Near(2, Read(Box("mdat", new byte[40], large: true), Box("moov", MovieHeader(0, 90000, 180000)))!.Value);
        Check.True(Read(Box("ftyp", new byte[8]), Box("mdat", new byte[16])) is null, "no moov");
        Check.True(Read(Box("moov", MovieHeader(0, 0, 10))) is null, "zero timescale");
        Check.True(MediaDuration.Read(new MemoryStream([0, 0, 0, 200, (byte)'m', (byte)'o'])) is null, "truncated");
    }

    [Test]
    public static void ReadsTheDemoPack()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "launcher-macos", "demo-pack"))) dir = dir.Parent;
        var demo = Path.Combine(dir!.FullName, "launcher-macos", "demo-pack");
        foreach (var file in new[] { "intro.mp4", "loop.mp4", "outro.mp4" })
        {
            var seconds = MediaDuration.Read(Path.Combine(demo, file));
            Check.True(seconds is > 0.5 and < 10, $"{file} = {seconds}");
        }
    }
}
