namespace GardenBoot.Core.Tests;

/// <summary>The built-in rainbow Welcome: nickname rules, what the pen writes, stroke tracing and the new-install default.</summary>
public static class GreetingTests
{
    [Test] public static void NicknameRules()
    {
        Check.Equal<string?>(null, Greeting.NormalizedName(null));
        Check.Equal<string?>(null, Greeting.NormalizedName("   "));
        Check.Equal<string?>("shishyguo", Greeting.NormalizedName("  shishyguo "));
        Check.Equal<string?>("小樱🌸", Greeting.NormalizedName("小樱🌸"));
        Check.Equal<string?>(new string('a', 20), Greeting.NormalizedName(new string('a', 20)));
        Check.Throws<ExperienceException>(() => Greeting.NormalizedName(new string('a', 21)));
        Check.Throws<ExperienceException>(() => Greeting.NormalizedName("two\nlines"));
    }

    [Test] public static void ScriptTextAndEmojiFallback()
    {
        Check.Equal("welcome shishyguo", Greeting.ScriptText("shishyguo"));
        Check.Equal("welcome", Greeting.ScriptText(null));
        Check.Equal("welcome", Greeting.ScriptText(""));
        Check.True(Greeting.ScriptCanWrite("shishyguo"));
        Check.True(Greeting.ScriptCanWrite(null));
        Check.True(Greeting.ScriptCanWrite("小樱"));
        Check.True(Greeting.ScriptCanWrite("Guo 2"));
        Check.False(Greeting.ScriptCanWrite("小樱🌸"));
        Check.False(Greeting.ScriptCanWrite("❤️"));
    }

    [Test] public static void NicknameIsStoredInExperienceSettings()
    {
        var settings = new ExperienceSettings { GreetingName = "shishyguo" };
        var copy = ExperienceSettings.Parse(settings.ToJson());
        Check.Equal("shishyguo", copy.GreetingName);
        Check.True(settings.ToJson().Contains("\"greetingName\": \"shishyguo\""), "camelCase key shared with macOS");
        Check.Equal<string?>(null, ExperienceSettings.Parse(new ExperienceSettings().ToJson()).GreetingName, "absent = none");
        var padded = new ExperienceSettings().ToJson().Replace("\"schemaVersion\": 3", "\"schemaVersion\": 3, \"greetingName\": \"  Sora \"");
        Check.Equal("Sora", ExperienceSettings.Parse(padded).GreetingName, "trimmed on read like macOS");
        var tooLong = new ExperienceSettings().ToJson().Replace("\"schemaVersion\": 3", $"\"schemaVersion\": 3, \"greetingName\": \"{new string('a', 21)}\"");
        Check.Throws<ExperienceException>(() => ExperienceSettings.Parse(tooLong));
    }

    [Test] public static void BuiltInWelcomeIsProcedural()
    {
        var json = """{"schemaVersion":1,"id":"sakura-greeting","name":"Welcome · 彩虹手写","segments":{"intro":"intro.mp4","outro":"outro.mp4"},"textOverlay":"greeting","cover":"cover.png"}""";
        var manifest = PackManifest.Parse(json);
        Check.True(manifest.ShowsGreeting);
        Check.Equal("greeting", PackManifest.Parse(manifest.ToJson()).TextOverlay, "round trip");
        Check.True(Greeting.IsProcedural(new InstalledPack(manifest, manifest.ValidatedLayout(), "/fixture")));
        var other = manifest with { Id = "my-pack" };
        Check.False(Greeting.IsProcedural(new InstalledPack(other, other.ValidatedLayout(), "/fixture")), "other packs keep their video");
    }

    [Test] public static void NewInstallStartsOnWelcomeAndKeepsChoices()
    {
        Check.Equal<string?>("sakura-greeting", PackLibrary.NewInstallChoice(null, false, "sakura-greeting"));
        foreach (var chosen in new[] { "raiden-garden", "demo-garden", "personal", "removed" })
        {
            Check.Equal<string?>(null, PackLibrary.NewInstallChoice(chosen, false, "sakura-greeting"), chosen);
            Check.Equal<string?>(null, PackLibrary.NewInstallChoice(chosen, true, "sakura-greeting"), chosen);
        }
        Check.Equal<string?>(null, PackLibrary.NewInstallChoice(null, true, "sakura-greeting"), "upgrade without a choice is left alone");
        Check.Equal("sakura-greeting", PackLibrary.PreferredAfterFirstFeaturedInstall("sakura-greeting", "raiden-garden"), "featured does not take over");
    }

    [Test] public static void ThickBarBecomesOneCentredStroke()
    {
        const int w = 200, h = 60;
        var mask = new byte[w * h];
        for (var y = 22; y < 38; y++) for (var x = 20; x < 180; x++) mask[y * w + x] = 255;
        var strokes = ScriptSkeleton.Strokes(mask, w, h, 100);
        Check.Equal(1, strokes.Count);
        Check.True(ScriptSkeleton.Length(strokes[0]) > 120);
        foreach (var p in strokes[0]) Check.Near(29.5, p.Y, 3);
        Check.True(strokes[0][0].X < strokes[0][^1].X, "the pen writes left to right");
    }

    [Test] public static void StrokesFollowWritingOrderAndKeepDots()
    {
        const int w = 300, h = 120;
        var mask = new byte[w * h];
        void Box(int x0, int y0, int x1, int y1) { for (var y = y0; y < y1; y++) for (var x = x0; x < x1; x++) mask[y * w + x] = 255; }
        Box(200, 60, 280, 70);
        Box(20, 60, 100, 70);
        Box(140, 20, 150, 29); // the dot of an i
        var strokes = ScriptSkeleton.Strokes(mask, w, h, 100);
        Check.Equal(3, strokes.Count);
        var starts = strokes.Select(s => s.Min(p => p.X)).ToList();
        Check.True(starts.SequenceEqual(starts.OrderBy(x => x)), "left to right");
    }

    [Test] public static void EmptyOrMalformedMaskGivesNoStrokes()
    {
        Check.Equal(0, ScriptSkeleton.Strokes([], 0, 0, 100).Count);
        Check.Equal(0, ScriptSkeleton.Strokes(new byte[100], 10, 10, 100).Count);
        Check.Equal(0, ScriptSkeleton.Strokes([1, 2, 3], 10, 10, 100).Count);
    }
}
