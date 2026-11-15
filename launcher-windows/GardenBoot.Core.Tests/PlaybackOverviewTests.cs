using System.Text.Json;
namespace GardenBoot.Core.Tests;

public static class PlaybackOverviewTests
{
    [Test]
    public static void SharedStatusPriorities()
    {
        DirectoryInfo? root = new(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "launcher-spec", "conformance", "overview.json"))) root = root.Parent;
        Check.True(root is not null, "shared overview fixtures exist");
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(root!.FullName, "launcher-spec", "conformance", "overview.json")));
        int count = 0;
        foreach (var item in doc.RootElement.GetProperty("cases").EnumerateArray())
        {
            count++;
            var input = JsonSerializer.Deserialize<PlaybackStatusInput>(item.GetProperty("input").GetRawText(),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
            Check.Equal(item.GetProperty("expect").GetString(), PlaybackStatusReason.Resolve(input).Code, item.GetProperty("name").GetString()!);
        }
        Check.Equal(18, count);
    }
}
