using GardenBoot.Core;
using System.Text.Json;
namespace GardenBoot.Core.Tests;
/// <summary>Explicit loopback/isolated-directory integration driver. Never compiled into Sakura.</summary>
public static class UpdateHarness
{
    public static async Task<int> Prepare(string[] a)
    {
        try
        {
            var uri = new Uri(a[1]);
            if (uri.Scheme != "http" || uri.Host != "127.0.0.1") throw new ArgumentException("loopback HTTP only");
            var work = Path.GetFullPath(a[2]); var target = Path.GetFullPath(a[3]);
            // The caller must supply an isolated marker; cannot point this harness at app-current.
            if (!File.Exists(Path.Combine(Path.GetDirectoryName(target)!, ".update-test-root"))) throw new ArgumentException("missing isolated-root marker");
            Directory.CreateDirectory(work);
            var sig = Path.Combine(work, "update.sig"); var zip = Path.Combine(work, "update.zip");
            await SignedUpdate.Download(new Uri(uri.AbsoluteUri + ".sig"), sig, 16384, _ => {}, CancellationToken.None, uri);
            using var cancellation = new CancellationTokenSource();
            if (uri.AbsolutePath.Contains("/cancel/")) cancellation.CancelAfter(150);
            await SignedUpdate.Download(uri, zip, SignedUpdate.MaxArchive, _ => {}, cancellation.Token, uri);
            var path = SignedUpdate.Prepare(zip, sig, target, a[4], "0.2.0-preview.7", work, ["--test-root", Path.GetFullPath(a[5])]);
            var request = JsonSerializer.Deserialize<SignedUpdate.Request>(File.ReadAllText(path))! with { Parent = int.Parse(a[6]) };
            File.WriteAllText(path, JsonSerializer.Serialize(request)); Console.WriteLine(path); return 0;
        }
        catch (Exception e) { Directory.CreateDirectory(a[2]); File.WriteAllText(Path.Combine(a[2], "error.txt"), e.ToString()); Console.Error.WriteLine(e.Message); return 1; }
    }
}
