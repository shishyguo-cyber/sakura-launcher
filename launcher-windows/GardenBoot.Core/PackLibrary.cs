namespace GardenBoot.Core;

/// <summary>What the app layer learns about a video file (media decoding lives outside the core).</summary>
public readonly record struct MediaInfo(double Duration, bool HasVideo);

/// <summary>Decodes enough of a file to say whether it can play. Injected so the core stays testable.</summary>
public delegate Task<MediaInfo> MediaProbe(string path);

/// <summary>Returns whether a file decodes as an image. Injected for the same reason as <see cref="MediaProbe"/>.</summary>
public delegate Task<bool> ImageProbe(string path);

public sealed record InstalledPack(PackManifest Manifest, PackLayout Layout, string Directory)
{
    public string Id => Manifest.Id;
    public string PathFor(string file) => System.IO.Path.Combine(Directory, file);
    public string NoticePath => PathFor(Manifest.NoticeFile);
    public string? CoverPath => Manifest.Cover is { } c ? PathFor(c) : null;
}

/// <summary>
/// Launch packs installed under one root (normally <c>%LOCALAPPDATA%\GardenBoot\Packs</c>), one folder per pack id.
/// </summary>
public sealed class PackLibrary(string root)
{
    public const string LegacyPackId = "imported-startup";
    public string Root { get; } = root;

    /// <summary>Reads and structurally validates a pack folder. Does not decode video.</summary>
    public static InstalledPack Load(string directory)
    {
        var manifestPath = Path.Combine(directory, PackDefaults.ManifestFile);
        string text;
        try { text = File.ReadAllText(manifestPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new PackException($"动画包缺少文件：{PackDefaults.ManifestFile}"); }
        var manifest = PackManifest.Parse(text);
        var layout = manifest.ValidatedLayout();
        foreach (var file in manifest.Segments.Values.Append(manifest.NoticeFile).Concat(manifest.Cover is { } c ? [c] : []))
        {
            if (!IsNonEmptyRegularFile(Path.Combine(directory, file))) throw new PackException($"动画包缺少文件：{file}");
        }
        return new InstalledPack(manifest, layout, directory);
    }

    /// <summary>Valid installed packs sorted by name, plus folder name → reason for anything skipped.</summary>
    public (IReadOnlyList<InstalledPack> Packs, IReadOnlyDictionary<string, string> Problems) Installed()
    {
        var packs = new List<InstalledPack>();
        var problems = new Dictionary<string, string>();
        if (!System.IO.Directory.Exists(Root)) return (packs, problems);
        foreach (var dir in System.IO.Directory.EnumerateDirectories(Root))
        {
            var folder = Path.GetFileName(dir);
            if (folder.StartsWith('.')) continue;
            try
            {
                var pack = Load(dir);
                if (pack.Id == folder) packs.Add(pack); else problems[folder] = "文件夹名与 id 不一致";
            }
            catch (PackException e) { problems[folder] = e.Message; }
        }
        packs.Sort((a, b) => (a.Manifest.Name, a.Id).CompareTo((b.Manifest.Name, b.Id)));
        return (packs, problems);
    }

    /// <summary>
    /// Validates <paramref name="source"/> completely (structure and every video), then installs a clean copy at
    /// <c>Root\&lt;id&gt;</c>. Only the manifest, referenced videos and the notice are copied. On any failure the
    /// previously installed pack with the same id is left as it was.
    /// </summary>
    public async Task<InstalledPack> ImportPack(string source, MediaProbe probe, ImageProbe? imageProbe = null)
    {
        var pack = Load(source);
        if (pack.Manifest.Cover is { } cover)
        {
            var coverPath = Path.Combine(source, cover);
            if (new FileInfo(coverPath).Length > PackDefaults.MaxCoverBytes) throw new PackException($"封面超过 8 MB：{cover}");
            bool decodes;
            try { decodes = imageProbe is null || await imageProbe(coverPath).ConfigureAwait(false); }
            catch (Exception) { decodes = false; }
            if (!decodes) throw new PackException($"封面无法作为图片打开：{cover}");
        }
        foreach (var segment in Enum.GetValues<PackSegment>())
        {
            if (!pack.Manifest.Segments.TryGetValue(segment, out var file)) continue;
            MediaInfo info;
            try { info = await probe(Path.Combine(source, file)).ConfigureAwait(false); }
            catch (Exception) { throw new PackException($"动画包里的视频无法播放：{file}"); }
            if (!info.HasVideo || !double.IsFinite(info.Duration) || info.Duration <= 0)
                throw new PackException($"动画包里的视频无法播放：{file}");
        }
        System.IO.Directory.CreateDirectory(Root);
        var staging = Path.Combine(Root, $".import-{Guid.NewGuid():N}");
        try
        {
            System.IO.Directory.CreateDirectory(staging);
            var files = new HashSet<string>(pack.Manifest.Segments.Values) { PackDefaults.ManifestFile, pack.Manifest.NoticeFile };
            if (pack.Manifest.Cover is { } coverFile) files.Add(coverFile);
            foreach (var file in files) File.Copy(Path.Combine(source, file), Path.Combine(staging, file));
            Load(staging);
            var destination = Path.Combine(Root, pack.Id);
            SwapIn(staging, destination);
            return Load(destination);
        }
        finally
        {
            if (System.IO.Directory.Exists(staging)) System.IO.Directory.Delete(staging, recursive: true);
        }
    }

    /// <summary>Installs a pack shipped with the app unless a valid pack with that id already exists.</summary>
    public async Task<InstalledPack?> InstallIfMissing(string bundled, MediaProbe probe, ImageProbe? imageProbe = null)
    {
        var pack = Load(bundled);
        try
        {
            var installed = Load(Path.Combine(Root, pack.Id));
            // An older copy of the bundled pack without the cover the app now ships is refreshed once.
            if (pack.Manifest.Cover is null || installed.Manifest.Cover is not null) return null;
        }
        catch (PackException) { }
        return await ImportPack(bundled, probe, imageProbe).ConfigureAwait(false);
    }

    /// <summary>
    /// Hands the installed folder of <paramref name="id"/> to <paramref name="moveToTrash"/> (the Recycle Bin in the app).
    /// The pack shipped with the app cannot be removed. Personal preferences live elsewhere and are not touched.
    /// </summary>
    public void Remove(string id, string bundledId, Action<string> moveToTrash)
    {
        if (!PlaybackState.IdPattern.IsMatch(id)) throw new PackException("动画包标识无效");
        if (id == bundledId) throw new PackException("随程序附带的示例包不能移除");
        var directory = Path.Combine(Root, id);
        if (!System.IO.Directory.Exists(directory)) throw new PackException("这个动画包已不存在");
        moveToTrash(directory);
    }

    /// <summary>Wraps a loose legacy video into a single-video pack. The original file is kept.</summary>
    public async Task<InstalledPack?> MigrateLegacyVideo(string video, MediaProbe probe)
    {
        if (!IsNonEmptyRegularFile(video)) return null;
        try { Load(Path.Combine(Root, LegacyPackId)); return null; } catch (PackException) { }
        System.IO.Directory.CreateDirectory(Root);
        var staging = Path.Combine(Root, $".legacy-{Guid.NewGuid():N}");
        try
        {
            System.IO.Directory.CreateDirectory(staging);
            var ext = Path.GetExtension(video).ToLowerInvariant();
            var file = "video" + (ext.Length > 0 ? ext : ".mp4");
            File.Copy(video, Path.Combine(staging, file));
            File.WriteAllText(Path.Combine(staging, PackDefaults.NoticeFile),
                "# 说明\n\n此视频由用户在旧版启动器中自行导入，权利归原提供者。仅供本机使用。\n");
            var manifest = new PackManifest(PackDefaults.SupportedSchema, LegacyPackId, "已导入的视频",
                                            new Dictionary<PackSegment, string> { [PackSegment.Video] = file });
            File.WriteAllText(Path.Combine(staging, PackDefaults.ManifestFile), manifest.ToJson());
            return await ImportPack(staging, probe).ConfigureAwait(false);
        }
        finally
        {
            if (System.IO.Directory.Exists(staging)) System.IO.Directory.Delete(staging, recursive: true);
        }
    }

    /// <summary>Only after the first successful featured installation: preserve a choice, otherwise select featured.
    /// The app's offered-once marker prevents removed packs from reaching this step again.</summary>
    public static string PreferredAfterFirstFeaturedInstall(string? preferredId, string featuredId) => preferredId ?? featuredId;

    /// <summary>The pack to play: the user's choice if still installed, else <paramref name="fallbackId"/>, else the first.</summary>
    public static InstalledPack? ResolveActive(string? preferredId, IReadOnlyList<InstalledPack> packs, string fallbackId) =>
        packs.FirstOrDefault(p => p.Id == preferredId) ?? packs.FirstOrDefault(p => p.Id == fallbackId) ?? packs.FirstOrDefault();

    /// <summary>
    /// Puts <paramref name="staging"/> at <paramref name="destination"/>. An existing folder is first moved aside and only
    /// deleted once the new one is in place; if the swap fails it is moved back.
    /// </summary>
    private static void SwapIn(string staging, string destination)
    {
        if (!System.IO.Directory.Exists(destination))
        {
            System.IO.Directory.Move(staging, destination);
            return;
        }
        var parked = destination + $".old-{Guid.NewGuid():N}";
        System.IO.Directory.Move(destination, parked);
        try { System.IO.Directory.Move(staging, destination); }
        catch
        {
            System.IO.Directory.Move(parked, destination);
            throw;
        }
        try { System.IO.Directory.Delete(parked, recursive: true); } catch (IOException) { }
    }

    internal static bool IsNonEmptyRegularFile(string path)
    {
        var info = new FileInfo(path);
        return info.Exists && info.LinkTarget is null && info.Length > 0;
    }
}
