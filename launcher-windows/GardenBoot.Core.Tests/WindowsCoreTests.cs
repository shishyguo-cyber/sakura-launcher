namespace GardenBoot.Core.Tests;

/// <summary>Pack library, process-group sessions, window choice and the log — the Windows-side core.</summary>
public static class WindowsCoreTests
{
    private static readonly MediaProbe GoodProbe = _ => Task.FromResult(new MediaInfo(2, true));

    private sealed class TempDir : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "gardenboot-" + Guid.NewGuid().ToString("N"));
        public TempDir() => Directory.CreateDirectory(Path);
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } }
    }

    private const string Segmented = """
        {"schemaVersion":1,"id":"demo-garden","name":"花园 · 示例",
         "segments":{"intro":"intro.mp4","loop":"loop.mp4","outro":"outro.mp4"}}
        """;

    private static string MakePack(string root, string name, string manifest, Dictionary<string, byte[]> files)
    {
        var dir = Path.Combine(root, "src-" + name);
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest);
        foreach (var (file, data) in files) File.WriteAllBytes(Path.Combine(dir, file), data);
        return dir;
    }

    private static Dictionary<string, byte[]> SegmentedFiles() => new()
    {
        ["intro.mp4"] = [1], ["loop.mp4"] = [2], ["outro.mp4"] = [3], ["NOTICE.md"] = "n"u8.ToArray(),
    };

    [Test]
    public static async Task ImportCopiesOnlyReferencedFiles()
    {
        using var t = new TempDir();
        var files = SegmentedFiles();
        files["private-raw.mov"] = [9];
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        var pack = await library.ImportPack(MakePack(t.Path, "ok", Segmented, files), GoodProbe);
        Check.Equal("demo-garden", pack.Id);
        var copied = Directory.GetFiles(pack.Directory).Select(Path.GetFileName).Order().ToArray();
        Check.Sequence(new[] { "NOTICE.md", "intro.mp4", "loop.mp4", "manifest.json", "outro.mp4" }.Order(), copied!);
        var (packs, problems) = library.Installed();
        Check.Sequence(["demo-garden"], packs.Select(p => p.Id));
        Check.Equal(0, problems.Count);
        Check.False(Directory.GetFileSystemEntries(library.Root).Any(e => Path.GetFileName(e).StartsWith('.')), "no staging left");
    }

    [Test]
    public static async Task MissingNoticeOrEmptyVideoIsRejected()
    {
        using var t = new TempDir();
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        var noNotice = SegmentedFiles();
        noNotice.Remove("NOTICE.md");
        var emptyLoop = SegmentedFiles();
        emptyLoop["loop.mp4"] = [];
        foreach (var (name, files) in new[] { ("nonotice", noNotice), ("emptyloop", emptyLoop) })
            await Check.ThrowsAsync<PackException>(() => library.ImportPack(MakePack(t.Path, name, Segmented, files), GoodProbe), name);
    }

    [Test]
    public static async Task FailedReimportKeepsInstalledPack()
    {
        using var t = new TempDir();
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        await library.ImportPack(MakePack(t.Path, "v1", Segmented, SegmentedFiles()), GoodProbe);
        var changed = SegmentedFiles();
        changed["outro.mp4"] = [7, 7];
        var v2 = MakePack(t.Path, "v2", Segmented, changed);
        MediaProbe nanOutro = p => Task.FromResult(new MediaInfo(Path.GetFileName(p) == "outro.mp4" ? double.NaN : 1, true));
        var e = await Check.ThrowsAsync<PackException>(() => library.ImportPack(v2, nanOutro));
        Check.True(e.Message.Contains("outro.mp4"), e.Message);
        MediaProbe broken = _ => throw new InvalidDataException();
        e = await Check.ThrowsAsync<PackException>(() => library.ImportPack(v2, broken));
        Check.True(e.Message.Contains("intro.mp4"), "first bad segment is named: " + e.Message);
        var installed = Path.Combine(library.Root, "demo-garden", "outro.mp4");
        Check.Sequence(["3"], File.ReadAllBytes(installed).Select(b => b.ToString()));
        await library.ImportPack(v2, GoodProbe);
        Check.Sequence(["7", "7"], File.ReadAllBytes(installed).Select(b => b.ToString()));
        Check.False(Directory.GetDirectories(library.Root).Any(d => Path.GetFileName(d).Contains(".old-")), "parked copy removed");
    }

    [Test]
    public static async Task InstallIfMissingKeepsUserCopy()
    {
        using var t = new TempDir();
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        var bundled = MakePack(t.Path, "bundled", Segmented, SegmentedFiles());
        Check.True(await library.InstallIfMissing(bundled, GoodProbe) is not null);
        var intro = Path.Combine(library.Root, "demo-garden", "intro.mp4");
        File.WriteAllBytes(intro, [5]);
        Check.True(await library.InstallIfMissing(bundled, GoodProbe) is null);
        Check.Sequence(["5"], File.ReadAllBytes(intro).Select(b => b.ToString()));
    }

    [Test]
    public static async Task LegacyVideoBecomesSingleVideoPack()
    {
        using var t = new TempDir();
        var legacy = Path.Combine(t.Path, "startup.mp4");
        File.WriteAllBytes(legacy, [4, 2]);
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        var pack = await library.MigrateLegacyVideo(legacy, GoodProbe);
        Check.Equal(PackLibrary.LegacyPackId, pack?.Id);
        Check.Equal(PackSegment.Video, pack!.Layout.FinalSegment);
        Check.True(File.Exists(pack.NoticePath));
        Check.True(File.Exists(legacy), "original kept");
        Check.True(await library.MigrateLegacyVideo(legacy, GoodProbe) is null, "only once");
        Check.True(await library.MigrateLegacyVideo(Path.Combine(t.Path, "missing.mp4"), GoodProbe) is null);
    }

    [Test]
    public static async Task BrokenOrMisnamedFoldersAreReported()
    {
        using var t = new TempDir();
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        var pack = await library.ImportPack(MakePack(t.Path, "ok", Segmented, SegmentedFiles()), GoodProbe);
        var renamed = Path.Combine(library.Root, "renamed");
        Directory.CreateDirectory(renamed);
        foreach (var f in Directory.GetFiles(pack.Directory)) File.Copy(f, Path.Combine(renamed, Path.GetFileName(f)));
        var broken = Path.Combine(library.Root, "broken");
        Directory.CreateDirectory(broken);
        File.WriteAllText(Path.Combine(broken, "manifest.json"), "{");
        var (packs, problems) = library.Installed();
        Check.Sequence(["demo-garden"], packs.Select(p => p.Id));
        Check.Sequence(["broken", "renamed"], problems.Keys.Order());
    }

    [Test]
    public static void ActivePackResolution()
    {
        static InstalledPack P(string id) => new(
            new PackManifest(1, id, id.ToUpperInvariant(), new Dictionary<PackSegment, string> { [PackSegment.Video] = "v.mp4" }),
            new PackLayout(null, null, "v.mp4", PackSegment.Video), "/tmp/" + id);
        var packs = new[] { P("a"), P("demo-garden"), P("night-garden") };
        Check.Equal("night-garden", PackLibrary.ResolveActive("night-garden", packs, "demo-garden")?.Id);
        Check.Equal("demo-garden", PackLibrary.ResolveActive("deleted", packs, "demo-garden")?.Id);
        Check.Equal("a", PackLibrary.ResolveActive(null, [P("a")], "demo-garden")?.Id);
        Check.True(PackLibrary.ResolveActive(null, [], "demo-garden") is null);
    }

    [Test]
    public static void ManifestRoundTrips()
    {
        var m = new PackManifest(1, "a", "A", new Dictionary<PackSegment, string> { [PackSegment.Intro] = "i.mp4", [PackSegment.Outro] = "o.mp4" },
                                 1.2, 0.5, 0.8, 12, LoopExit.Immediate, "LICENSE.md");
        var back = PackManifest.Parse(m.ToJson());
        Check.Equal(m.ToJson(), back.ToJson());
        Check.Equal(m.ValidatedLayout(), back.ValidatedLayout());
    }

    [Test]
    public static void ColdLaunchIsTheStepFromNoProcessToSome()
    {
        var s = new TargetSession([]);
        Check.Equal(SessionChange.None, s.Update([]));
        Check.Equal(SessionChange.Started, s.Update([10]));
        Check.Equal(SessionChange.None, s.Update([10, 11, 12]), "helpers of the same launch");
        Check.Equal(SessionChange.None, s.Update([11]), "main restarts a helper");
        Check.Equal(SessionChange.Ended, s.Update([]));
        Check.Equal(SessionChange.Started, s.Update([20]), "next cold launch");
    }

    [Test]
    public static void RunningAtStartIsBaseline()
    {
        var s = new TargetSession([5, 6]);
        Check.True(s.IsActive && s.IsBaseline);
        Check.Equal(SessionChange.None, s.Update([5, 6, 7]));
        Check.Equal(SessionChange.Ended, s.Update([]));
        Check.False(s.IsBaseline);
        Check.Equal(SessionChange.Started, s.Update([8]));
        Check.False(s.IsBaseline);
    }

    [Test]
    public static void ChoosesTheFrontmostRealWindowOfTheTarget()
    {
        var target = new HashSet<int> { 42, 43 };
        TopWindow W(int pid, double w = 1000, double h = 700, bool visible = true, bool owned = false, bool tool = false, bool cloaked = false, nint hwnd = 0) =>
            new(hwnd, pid, visible, owned, tool, cloaked, new Box(100, 40, w, h));
        var list = new[]
        {
            W(7, hwnd: 1),                 // another app in front
            W(42, hwnd: 2, tool: true),    // tool window
            W(42, hwnd: 3, cloaked: true), // cloaked (other virtual desktop / not yet shown)
            W(42, hwnd: 4, owned: true),   // owned popup
            W(43, 200, 120, hwnd: 5),      // too small
            W(42, hwnd: 6, visible: false),
            W(43, hwnd: 7),                // the main window, from a sibling process
            W(42, 1400, 900, hwnd: 8),     // bigger but behind
        };
        Check.Equal((nint)7, WindowChooser.MainWindow(list, target)?.Handle);
        Check.True(WindowChooser.MainWindow(list, new HashSet<int> { 99 }) is null);
    }

    [Test]
    public static void EventLogAppendsAndRotates()
    {
        using var t = new TempDir();
        var log = new EventLog(t.Path, 200);
        log.Write("first");
        log.Write("second");
        var text = File.ReadAllText(log.Path);
        Check.Equal(2, text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length);
        Check.True(text.EndsWith(" second\n"));
        for (var i = 0; i < 10; i++) log.Write($"event-{i}-" + new string('x', 20));
        text = File.ReadAllText(log.Path);
        Check.True(text.Length <= 200, "rotated under limit");
        Check.True(text.Contains("event-9-"));
        Check.True(File.Exists(log.PreviousPath));
    }

    [Test]
    public static void LaunchFrameInvariants()
    {
        foreach (var visible in new[] { new Box(0, 0, 1920, 1040), new Box(-1280, 200, 1280, 984), new Box(0, 0, 3840, 2100) })
        foreach (var aspect in new[] { 16.0 / 9, 4.0 / 3, 2.39 })
        {
            var f = OverlayGeometry.LaunchFrame(visible, aspect);
            Check.True(visible.Contains(f), $"{visible} {aspect}");
            Check.True(f.Width <= OverlayGeometry.LaunchMaxWidth);
            Check.Near(aspect, f.Width / f.Height, 0.02);
        }
    }

    private const string WithCover = """
        {"schemaVersion":1,"id":"covered","name":"带封面","segments":{"video":"v.mp4"},"cover":"cover.png"}
        """;

    private static Dictionary<string, byte[]> CoverFiles() => new() { ["v.mp4"] = [1], ["NOTICE.md"] = "n"u8.ToArray(), ["cover.png"] = [7, 7] };

    [Test]
    public static async Task CoverIsValidatedAndCopied()
    {
        using var t = new TempDir();
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        ImageProbe good = _ => Task.FromResult(true);
        var pack = await library.ImportPack(MakePack(t.Path, "cover", WithCover, CoverFiles()), GoodProbe, good);
        Check.True(File.Exists(Path.Combine(pack.Directory, "cover.png")), "cover copied");
        Check.Equal(Path.Combine(pack.Directory, "cover.png"), pack.CoverPath);

        var missing = CoverFiles(); missing.Remove("cover.png");
        await Check.ThrowsAsync<PackException>(() => library.ImportPack(MakePack(t.Path, "nocover", WithCover, missing), GoodProbe, good), "missing cover");
        await Check.ThrowsAsync<PackException>(() => library.ImportPack(MakePack(t.Path, "badimg", WithCover, CoverFiles()), GoodProbe, _ => Task.FromResult(false)), "undecodable cover");
        await Check.ThrowsAsync<PackException>(() => library.ImportPack(MakePack(t.Path, "throws", WithCover, CoverFiles()), GoodProbe, _ => throw new IOException()), "probe failure");
        var big = CoverFiles(); big["cover.png"] = new byte[PackDefaults.MaxCoverBytes + 1];
        await Check.ThrowsAsync<PackException>(() => library.ImportPack(MakePack(t.Path, "big", WithCover, big), GoodProbe, good), "oversized cover");
        Check.True(File.Exists(Path.Combine(pack.Directory, "cover.png")), "failed re-imports keep the installed pack");

        var plain = await library.ImportPack(MakePack(t.Path, "plain", Segmented, SegmentedFiles()), GoodProbe);
        Check.True(plain.CoverPath is null);
    }

    [Test]
    public static async Task RemoveMovesPackAsideButNotBundled()
    {
        using var t = new TempDir();
        var library = new PackLibrary(Path.Combine(t.Path, "Packs"));
        var pack = await library.ImportPack(MakePack(t.Path, "ok", Segmented, SegmentedFiles()), GoodProbe);
        string? removed = null;
        Check.Throws<PackException>(() => library.Remove(pack.Id, bundledId: "demo-garden", moveToTrash: d => removed = d), "bundled pack");
        Check.True(removed is null);
        var other = await library.ImportPack(MakePack(t.Path, "cover", WithCover, CoverFiles()), GoodProbe, _ => Task.FromResult(true));
        library.Remove(other.Id, bundledId: "demo-garden", moveToTrash: d => { removed = d; Directory.Delete(d, true); });
        Check.Equal(other.Directory, removed);
        Check.Sequence(["demo-garden"], library.Installed().Packs.Select(p => p.Id));
        Check.Throws<PackException>(() => library.Remove("not-here", bundledId: "demo-garden", moveToTrash: _ => { }), "missing pack");
        Check.Throws<PackException>(() => library.Remove("../x", bundledId: "demo-garden", moveToTrash: _ => { }), "bad id");
    }

    [Test]
    public static void AvailableIdsAreOrdinalSorted()
    {
        var packs = new[] { "b", "a-2", "a" }.Select(id => new InstalledPack(
            new PackManifest(1, id, "Z" + id, new Dictionary<PackSegment, string> { [PackSegment.Video] = "v.mp4" }),
            new PackLayout(null, null, "v.mp4", PackSegment.Video), id)).ToList();
        Check.Sequence(["a", "a-2", "b"], PackRotationRules.AvailableIds(packs));
    }
}
