using System.Text;
using System.Text.Json;
using GardenBoot.Core;
namespace GardenBoot.Core.Tests;
public static class SignedUpdateTests
{
    [Test] public static void LargePrereleaseAndCanonicalVersions()
    {
        Check.Equal<int?>(1, UpdateRules.Compare("0.2.0-preview.999999999999999999999999", "0.2.0-preview.8"));
        Check.Throws<SignedUpdate.Failure>(() => SignedUpdate.Asset("0.2.0-preview.8+metadata", "0.2.0-preview.7", "windows-x64"));
    }
    [Test] public static void VersionsAndSharedSignatures()
    {
        Check.Throws<SignedUpdate.Failure>(() => SignedUpdate.Asset("0.2.0-preview.7", "0.2.0-preview.7", "windows-x64"));
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "launcher-spec"))) directory = directory.Parent;
        Check.Equal(File.ReadAllText(Path.Combine(directory!.FullName, "launcher-spec/update-public-key.txt")).Trim(), SignedUpdate.PublicKey);
        using var vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory!.FullName, "launcher-spec/conformance/signed-updates.json")));
        foreach (var v in vectors.RootElement.EnumerateArray())
        {
            bool valid; string state;
            try { SignedUpdate.Verify(v.GetProperty("manifest").GetRawText(), Encoding.UTF8.GetBytes(v.GetProperty("payload").GetString()!), v.GetProperty("version").GetString()!, "0.2.0-preview.7", v.GetProperty("platform").GetString()!); valid = true; state = "confirmed";
                Check.Equal(v.GetProperty("asset").GetString(), SignedUpdate.Asset(v.GetProperty("version").GetString()!, "0.2.0-preview.7", v.GetProperty("platform").GetString()!).AbsoluteUri); }
            catch (SignedUpdate.Failure e) { valid = false; state = e.Code; }
            Check.Equal(v.GetProperty("state").GetString(), state);
            Check.Equal(v.GetProperty("valid").GetBoolean(), valid, v.GetProperty("name").GetString()!);
        }
    }
}
