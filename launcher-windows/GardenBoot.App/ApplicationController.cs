using System.Diagnostics;
using System.IO;
using System.Security;
using System.Windows;
using GardenBoot.Core;
using Microsoft.Win32;
using EventLog = GardenBoot.Core.EventLog;

namespace GardenBoot.App;

internal sealed class ApplicationController : IDisposable, ILibraryActions, IOverviewRuntime
{
    private const string BundledId = "demo-garden";
    private readonly PlaybackStateStore stateStore;
    private PlaybackState playState = new();
    private MediaClip? warmClip; // first segment of the active pack, prerolled at frame 0 (LAUNCH-LATENCY.md)
    private readonly AppOptions options;
    private readonly EventLog log;
    private readonly Settings settings;
    private readonly PackLibrary library;
    private readonly WindowsMediaProbe media;
    private readonly TargetMonitor monitor;
    private readonly TrayIcon tray;
    private readonly Stopwatch lifetime = Stopwatch.StartNew();
    private readonly CancellationTokenSource shutdown = new();
    private LaunchOverlay? player;
    private ExperienceSettings experience = new();
    private readonly ExperienceStore experienceStore;
    private ExperienceWindow? experienceWindow;
    private string experienceWarning = "";
    private readonly Dictionary<string, string> failedOverviewPacks = new();
    private InstalledPack? activePack;
    private IReadOnlyList<InstalledPack> packs = [];
    private int problems;
    private IReadOnlyDictionary<string, string> problemList = new Dictionary<string, string>();
    private bool libraryBusy, disposed;
    private Guid generation;
    private string status = "正在准备动画…";

    public ApplicationController(AppOptions options)
    {
        this.options = options;
        log = new(options.DataRoot);
        settings = Settings.Load(options.DataRoot, log);
        experienceStore = new(options.DataRoot);
        try { experience = experienceStore.Load(); }
        catch (Exception e) when (e is ExperienceException or IOException or UnauthorizedAccessException)
        { experienceWarning = e.Message; log.Write("experience-load-failed"); }
        stateStore = new(options.DataRoot);
        (playState, var stateReset) = stateStore.Load();
        if (stateReset) log.Write("playback-state-reset");
        library = new(Path.Combine(options.DataRoot, "Packs"));
        media = new(Application.Current.Dispatcher);
        monitor = new(WatchedTargets());
        tray = new() { BuildMenu = BuildMenu };
        monitor.Changed += SessionChanged;
        monitor.Reappeared += Reappeared;
        monitor.Stalled += gap => log.Write(FormattableString.Invariant($"monitor-stall seconds={gap:F2}"));
        SystemEvents.PowerModeChanged += PowerModeChanged;
        monitor.ForegroundChanged += ForegroundChanged;
    }

    public void Start()
    {
        ReloadPacks();
        var bundled = Path.Combine(AppContext.BaseDirectory, "demo-pack");
        // Listen immediately, even while the first-run validated library copy is being installed.
        if (activePack is null)
        {
            try { activePack = PackLibrary.Load(bundled); }
            catch (PackException) { }
        }
        if (!monitor.Start()) log.Write("foreground-hook-unavailable");
        log.Write($"monitor-started targets={string.Join(",", monitor.TargetIds)} baseline={monitor.TargetIds.Sum(id => monitor.SessionOf(id).Processes.Count)} at-login={options.AtLogin}");
        _ = InstallBundled(bundled);
        StartUpdateChecks();
    }

    /// <summary>
    /// Installs the bundled featured pack once per user; selects it only when no current choice exists. Test
    /// roots skip it unless --test-featured, so controlled checks keep using the demo pack.
    /// </summary>
    private async Task InstallFeatured()
    {
        if (options.TestRoot is not null && !options.TestFeatured) return;
        var folder = Path.Combine(AppContext.BaseDirectory, "featured-pack");
        InstalledPack bundled;
        try { bundled = PackLibrary.Load(folder); }
        catch (Exception e) when (e is PackException or IOException) { return; }
        if (settings.FeaturedInstalled.Contains(bundled.Id)) return;
        libraryBusy = true;
        try
        {
            var installed = await library.InstallIfMissing(folder, Probe, ImageProbe);
            // Persist "offered once" before reporting, so a quit right after installing never reinstalls it.
            settings.FeaturedInstalled.Add(bundled.Id);
            var previousId = settings.ActivePackId;
            var preferredId = PackLibrary.PreferredAfterFirstFeaturedInstall(previousId, bundled.Id);
            if (previousId is null) settings.ActivePackId = preferredId;
            SaveSettings();
            if (installed is not null) log.Write($"pack-installed id={installed.Id} featured=true");
            if (previousId is null) log.Write($"featured-made-current id={bundled.Id}");
        }
        catch (Exception e) when (e is PackException or IOException or UnauthorizedAccessException or OperationCanceledException)
        { if (!disposed) log.Write($"featured-pack-error type={e.GetType().Name}"); }
        finally { libraryBusy = false; }
    }

    private async Task InstallBundled(string bundled)
    {
        libraryBusy = true;
        try
        {
            if (await library.InstallIfMissing(bundled, Probe, ImageProbe) is { } installed)
                log.Write($"pack-installed id={installed.Id}");
        }
        catch (Exception e) when (e is PackException or IOException or UnauthorizedAccessException or OperationCanceledException)
        { if (!disposed) log.Write($"bundled-pack-error type={e.GetType().Name}"); }
        finally { libraryBusy = false; }
        if (disposed) return;
        await InstallFeatured();
        if (disposed) return;
        ReloadPacks();
        if (player is null) status = settings.Paused ? "自动播放已暂停" : Waiting();
        if (options.Preview) Play(true);
        if (options.TestCompat is { } compatTarget) ((ILibraryActions)this).TestTarget(compatTarget);
        if (options.TestCreateVideo is { } testVideo) await CreateFromVideo(testVideo);
        if (options.RequestSettings || showWhenReady)
        {
            log.Write("settings-opened-on-launch");
            OpenSettings();
        }
        if (options.UpdateReady is { } ack) File.WriteAllText(ack, ReleaseVersion);
        if (options.UpdateFailed && MessageBox.Show("更新未完成，已保留或恢复旧版。去 GitHub 手动下载？", "更新失败", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes) OpenUpdateFallback();
    }

    private Task<bool> ImageProbe(string path) =>
        Application.Current.Dispatcher.InvokeAsync(() => PackThumbnails.CanDecode(path)).Task;

    private static double UnixNow() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    private static double Offset(double unix) =>
        TimeZoneInfo.Local.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds((long)(unix * 1000))).TotalSeconds;
    private string CacheRoot => options.TestRoot is { } root ? Path.Combine(root, "Cache")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GardenBoot", "Cache");

    private void SaveState()
    {
        try { stateStore.Save(playState); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        { log.Write($"playback-state-save-failed type={e.GetType().Name}"); }
    }

    private Task<MediaInfo> Probe(string path)
    {
        shutdown.Token.ThrowIfCancellationRequested();
        return media.Probe(path, shutdown.Token);
    }

    /// <summary>Enabled targets with a Windows identity; a test executable replaces them all (launcher-spec/TARGETS.md §5).</summary>
    private IReadOnlyList<WatchedTarget> WatchedTargets() => options.TestTargetExe is { } test
        ? [new("test", new WindowsTargetIdentity { Path = test }, options.TestReappear)]
        : experience.Targets.Where(t => t.Enabled && t.Windows is not null).Select(t => new WatchedTarget(t.Id, t.Windows!, t.PlayOnReappear)).ToList();

    private string Waiting() => monitor.TargetIds.Count switch
    {
        0 => "还没有启用的应用",
        1 => "正在等待应用启动",
        var n => $"正在等待 {n} 个应用启动",
    };

    private LaunchTarget? TargetOf(string id) => experience.Targets.FirstOrDefault(t => t.Id == id);

    private void SessionChanged(string targetId, SessionChange change)
    {
        if (change == SessionChange.Ended)
        {
            log.Write($"target-exited target={targetId}");
            if (player is { IsPreview: false } current && current.TargetId == targetId) current.Send(new PlaybackEvent.TargetExited());
            return;
        }
        if (change != SessionChange.Started) return;
        if (compat is { ColdAt: null } test && test.Id == targetId)
        {
            test.ColdAt = test.Clock.Elapsed.TotalSeconds;
            log.Write($"compat-cold target={targetId}");
            Launch(targetId, "cold", testing: true);
            return;
        }
        Launch(targetId, "cold", testing: false);
    }

    private void Reappeared(string targetId)
    {
        log.Write($"target-reappeared target={targetId}");
        Launch(targetId, "reappear", testing: false);
    }

    /// <summary>Quiet when the user is in a full-screen app, game or presentation (COMPATIBILITY.md §3).</summary>
    private static QuietState CurrentQuietState() => Native.SHQueryUserNotificationState(out var state) != 0 ? QuietState.Normal : state switch
    {
        2 => QuietState.Fullscreen, 3 => QuietState.Game, 4 => QuietState.Presentation, _ => QuietState.Normal,
    };

    /// <summary>
    /// A target started (cold) or brought a window back (reappear): policy → login filter → quiet → busy → frequency → pack.
    /// A compatibility test skips the checks and records nothing for the day.
    /// </summary>
    private void Launch(string targetId, string kind, bool testing)
    {
        var processes = monitor.SessionOf(targetId).Processes;
        var mine = playState.For(targetId);
        if (!testing)
        {
            if (!PlaybackPolicy.ShouldAutoPlay(settings.Paused, TargetMonitor.ReduceMotion, settings.PlayDespiteReduceMotion))
            { log.Write($"playback-skipped reason=policy target={targetId}"); return; }
            if (kind == "cold" && options.TestRoot is null && LaunchFilter.Skip(TargetMonitor.IsHidden(processes), lifetime.Elapsed.TotalSeconds,
                options.AtLogin, Environment.TickCount64 / 1000.0) is { } skip)
            { log.Write($"playback-skipped reason={skip.LogName()} target={targetId}"); return; }
            var (quiet, detail) = QuietRules.Skip(experience.Playback.QuietWhenFullscreen, options.TestQuiet ?? CurrentQuietState());
            if (quiet) { log.Write($"playback-skipped reason=quiet target={targetId} detail={detail}"); return; }
            // One animation at a time: another app opening during playback (or a preview) does not interrupt it.
            if (player is not null) { log.Write($"playback-skipped reason=busy target={targetId}"); return; }
            var now = UnixNow();
            var outcome = ScheduleDecision.Decide(experience.Playback.Frequency, experience.Playback.DayStartHour, mine, now, Offset(now),
                                                  mine.LastAutoPlayAt is { } last ? Offset(last) : Offset(now));
            if (outcome != ScheduleOutcome.Play)
            { log.Write($"playback-skipped reason={(outcome == ScheduleOutcome.Snoozed ? "snoozed" : "played-today")} target={targetId}"); return; }
        }
        log.Write($"launch-detected target={targetId} kind={kind} pid={string.Join(",", processes.Order())}");
        var animation = TargetOf(targetId)?.Animation;
        var (chosenId, missing) = TargetRules.ChoosePack(animation, experience.Library.Rotation, experience.Library.Favorites,
                                                         PackRotationRules.AvailableIds(packs), activePack?.Id, mine.LastPackId, Random.Shared.NextDouble());
        if (missing) log.Write($"target-pack-missing target={targetId} pack={animation}");
        var chosen = packs.FirstOrDefault(p => p.Id == chosenId) ?? activePack;
        var rule = animation is not null && !missing ? "target" : experience.Library.Rotation.LogName();
        log.Write($"pack-chosen id={chosen?.Id ?? "none"} rotation={rule} target={targetId}");
        if (testing && compat is { } test) test.Pack = chosen;
        Play(false, requestedPack: chosen, targetId: targetId, record: !testing);
    }

    // ---------- "测试一下" (COMPATIBILITY.md §1) ----------

    private sealed class CompatTest(string id, bool runningAtStart)
    {
        public string Id { get; } = id;
        public bool RunningAtStart { get; } = runningAtStart;
        public System.Diagnostics.Stopwatch Clock { get; } = System.Diagnostics.Stopwatch.StartNew();
        public double? ColdAt { get; set; }
        public double? WindowSeconds { get; set; }
        public InstalledPack? Pack { get; set; }
    }
    private CompatTest? compat;
    private System.Windows.Threading.DispatcherTimer? compatTimer;

    void ILibraryActions.TestTarget(string id)
    {
        if (!monitor.TargetIds.Contains(id))
        {
            MessageBox.Show("请先保存设置并打开这个应用的开关，再测试。", "Sakura", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        player?.Send(new PlaybackEvent.Superseded());
        compat = new CompatTest(id, monitor.SessionOf(id).IsActive);
        log.Write($"compat-start target={id} running={compat.RunningAtStart.ToString().ToLowerInvariant()}");
        compatTimer?.Stop();
        compatTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        compatTimer.Tick += (_, _) => CompatTick();
        compatTimer.Start();
        RefreshWindow();
    }

    private void CompatTick()
    {
        if (compat is not { } test) { compatTimer?.Stop(); return; }
        var elapsed = test.Clock.Elapsed.TotalSeconds;
        if (test.ColdAt is { } cold && test.WindowSeconds is null && TargetMonitor.MainWindow(monitor.SessionOf(test.Id).Processes) is not null)
        {
            test.WindowSeconds = Math.Round(elapsed - cold, 1);
            log.Write(FormattableString.Invariant($"compat-window target={test.Id} seconds={test.WindowSeconds}"));
        }
        var settled = test.ColdAt is not null && test.WindowSeconds is not null && player is null;
        if (!settled && elapsed < (options.TestCompatSeconds ?? CompatibilityRules.TestSeconds)) return;
        compatTimer?.Stop();
        var pack = test.Pack ?? activePack;
        var maxWait = pack is null ? PackDefaults.MaxWaitSeconds : experience.Resolve(pack.Manifest).EffectiveMaxWait;
        var verdict = CompatibilityRules.Verdict(test.RunningAtStart, test.ColdAt is not null, test.WindowSeconds, maxWait);
        playState.RecordCompat(test.Id, new(verdict, test.WindowSeconds, UnixNow()));
        SaveState();
        log.Write(FormattableString.Invariant($"compat-result target={test.Id} verdict={verdict.LogName()} window={(test.WindowSeconds?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "none")}"));
        compat = null;
        RefreshWindow();
    }

    private void ForegroundChanged(int pid)
    {
        if (player is { } overlay)
        {
            var isTarget = !overlay.IsPreview && monitor.IsTargetProcess(overlay.TargetId, pid);
            if (PlaybackPolicy.EndsOnActivation(pid == Environment.ProcessId, isTarget, overlay.Age))
            {
                log.Write(FormattableString.Invariant($"foreground-cancel pid={pid} age={overlay.Age:F3} preview={overlay.IsPreview}"));
                overlay.Send(new PlaybackEvent.UserSwitched());
            }
        }
    }

    private void Play(bool preview, ExperienceSettings? draft = null, InstalledPack? requestedPack = null, string? targetId = null, bool record = true)
    {
        var token = generation = Guid.NewGuid();
        player?.Send(new PlaybackEvent.Superseded());
        player = null;
        if ((requestedPack ?? activePack) is not { } original)
        {
            status = "还没有可用的动画";
            log.Write("playback-skipped reason=no-configured-pack");
            return;
        }
        var preferences = draft ?? experience;
        InstalledPack pack;
        try { var manifest = preferences.Resolve(original.Manifest); pack = original with { Manifest = manifest, Layout = manifest.ValidatedLayout() }; }
        catch (ExperienceException) { status = "无法播放：个人设置无效"; return; }
        log.Write(FormattableString.Invariant($"experience-applied pack={pack.Id} preview={preview} volume={pack.Manifest.EffectiveVolume} fade={pack.Manifest.EffectiveFadeDuration} coverage={preferences.Coverage(pack.Id)} fit={pack.Manifest.EffectiveVideoFit.LogName()}"));
        var overlay = new LaunchOverlay(pack, monitor, tray, log, preview, reason =>
        {
            if (generation != token) return;
            player = null;
            if (reason.Kind == EndKind.Failed) failedOverviewPacks[targetId ?? "preview"] = pack.Id;
            if (reason.Kind == EndKind.Completed)
                foreach (var key in failedOverviewPacks.Where(x => x.Value == pack.Id).Select(x => x.Key).ToArray()) failedOverviewPacks.Remove(key);
            Rewarm();
            if (preview && experienceWindow is { IsVisible: true } editor) editor.ReportPreview(reason);
            status = settings.Paused ? "自动播放已暂停" : Waiting();
        }, coverage: preferences.Coverage(pack.Id), warmFirst: TakeWarm(pack), targetId: targetId);
        player = overlay;
        status = $"正在播放：{pack.Manifest.Name}";
        overlay.Begin();
        if (!preview && targetId is not null && record)
        {
            playState.Record(targetId, UnixNow(), pack.Id);
            SaveState();
        }
    }

    private static PackSegment FirstSegment(InstalledPack pack) =>
        pack.Layout.Intro is not null ? PackSegment.Intro : pack.Layout.Loop is not null ? PackSegment.Loop : pack.Layout.FinalSegment;

    /// <summary>Hands the warm clip to a playback of the same pack; the next idle moment prepares a new one.</summary>
    private MediaClip? TakeWarm(InstalledPack pack)
    {
        var clip = warmClip;
        warmClip = null;
        if (clip is not null && clip.Path == pack.PathFor(pack.Manifest.Segments[FirstSegment(pack)])) return clip;
        clip?.Dispose();
        return null;
    }

    /// <summary>Prepares the active pack's first segment while idle. Rebuilt when the pack or its files change.</summary>
    private void Rewarm()
    {
        if (disposed || player is not null) return;
        if (activePack is not { } pack || libraryBusy) { warmClip?.Dispose(); warmClip = null; return; }
        var segment = FirstSegment(pack);
        var path = pack.PathFor(pack.Manifest.Segments[segment]);
        if (warmClip is { } existing && existing.Path == path && !existing.Ready.IsFaulted && !existing.Ready.IsCanceled) return;
        warmClip?.Dispose();
        try { warmClip = new MediaClip(path, segment == PackSegment.Loop); }
        catch (Exception e) when (e is IOException or UriFormatException or InvalidOperationException)
        { warmClip = null; log.Write($"warm-failed type={e.GetType().Name}"); }
    }

    private void ReloadPacks()
    {
        try
        {
            var installed = library.Installed();
            packs = installed.Packs;
            problems = installed.Problems.Count;
            activePack = PackLibrary.ResolveActive(settings.ActivePackId, packs, BundledId);
            problemList = installed.Problems;
            log.Write($"packs-loaded count={packs.Count} skipped={problems} active={activePack?.Id ?? "none"}");
            Rewarm();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        { log.Write($"packs-load-failed type={e.GetType().Name}"); status = "无法读取动画文件夹"; }
    }

    // ---------- Update check (launcher-spec/UPDATES.md) ----------

    private static readonly System.Net.Http.HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private System.Windows.Threading.DispatcherTimer? updateTimer;
    private bool updateChecking;
    private CancellationTokenSource? installCancellation;

    internal static string ReleaseVersion
    {
        get
        {
            var info = typeof(ApplicationController).Assembly
                .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
                .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion ?? "0.0.0";
            return info.Split('+')[0];
        }
    }

    private string updateMessage = "尚未检查更新";
    private bool AutoUpdateEnabled => settings.AutoCheckUpdates ?? (options.TestRoot is null || options.TestCheckUpdate);

    /// <summary>A newer version found earlier; dropped once this build is at least that version.</summary>
    private UpdateRules.Available? AvailableUpdate()
    {
        if (settings.UpdateAvailableVersion is { } version && settings.UpdateAvailableUrl is { } url
            && (UpdateRules.Compare(version, ReleaseVersion) ?? 0) > 0) return new(version, url);
        return null;
    }

    private void StartUpdateChecks()
    {
        if (AvailableUpdate() is { } known) log.Write($"update-available latest={known.Version}");
        var first = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(options.TestCheckUpdate ? 0.5 : 60) };
        first.Tick += (_, _) => { first.Stop(); _ = CheckForUpdates(manual: false); };
        first.Start();
        updateTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromHours(6) };
        updateTimer.Tick += (_, _) => _ = CheckForUpdates(manual: false);
        updateTimer.Start();
    }

    private async Task<IReadOnlyList<UpdateRules.Release>> FetchReleases()
    {
        if (options.TestUpdateFeed is { } feed) return UpdateRules.DecodeReleases(await File.ReadAllTextAsync(feed));
        if (options.TestRoot is not null) throw new System.Net.Http.HttpRequestException("network disabled in isolated test roots");
        using var request = new System.Net.Http.HttpRequestMessage(System.Net.Http.HttpMethod.Get, UpdateRules.ReleasesUrl);
        request.Headers.UserAgent.ParseAdd("Sakura/" + ReleaseVersion);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await Http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return UpdateRules.DecodeReleases(await response.Content.ReadAsStringAsync());
    }

    private async Task CheckForUpdates(bool manual, bool showAlert = true)
    {
        if (updateChecking || installCancellation is not null || disposed) return;
        if (!manual && (!AutoUpdateEnabled || !UpdateRules.IsDue(settings.UpdateLastCheckAt, UnixNow()))) return;
        var source = manual ? "manual" : "auto";
        updateChecking = true;
        updateMessage = "正在检查更新…";
        try
        {
            var releases = await FetchReleases();
            if (disposed) return;
            settings.UpdateLastCheckAt = UnixNow();
            var newer = UpdateRules.Newest(releases, ReleaseVersion);
            settings.UpdateAvailableVersion = newer?.Version;
            settings.UpdateAvailableUrl = newer?.Url;
            SaveSettings();
            if (newer is not null)
            {
                log.Write($"update-check source={source} result=newer latest={newer.Version}");
                log.Write($"update-available latest={newer.Version}");
                updateMessage = $"发现新版本 {newer.Version}";
                if (manual && showAlert) OpenSettings();
            }
            else
            {
                log.Write($"update-check source={source} result=current latest=none");
                updateMessage = $"已是最新版本（{ReleaseVersion}）。";
                if (manual && showAlert) MessageBox.Show($"已是最新版本（{ReleaseVersion}）。", "检查更新", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }
        catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or System.Text.Json.JsonException or IOException or UnauthorizedAccessException)
        {
            if (disposed) return;
            log.Write($"update-check source={source} result=failed latest=none error={e.GetType().Name}");
            updateMessage = "暂时无法检查更新，请稍后再试。";
            if (manual && showAlert) MessageBox.Show("暂时无法检查更新，请稍后再试。", "检查更新", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { updateChecking = false; }
    }

    public UpdateOverview UpdateOverview() => new(ReleaseVersion, AutoUpdateEnabled, updateChecking,
        updateMessage == "尚未检查更新" && AvailableUpdate() is { } newer ? $"发现新版本 {newer.Version}" : updateMessage, AvailableUpdate()?.Version, Installing: installCancellation is not null);
    public void CheckForUpdatesFromSettings() => _ = CheckForUpdates(manual: true, showAlert: false);
    public void OpenUpdateDownload() { if (installCancellation is not null) { installCancellation.Cancel(); return; } _ = InstallUpdate(); }
    public void OpenUpdateFallback() => OpenUpdatePage("https://github.com/shishyguo-cyber/sakura-launcher/releases");
    private async Task InstallUpdate()
    {
        if (AvailableUpdate() is not { } newer || installCancellation is not null) return;
        using var cancellation = new CancellationTokenSource(); installCancellation = cancellation;
        var work = Path.Combine(Path.GetTempPath(), "Sakura-update-" + Guid.NewGuid()); string? staged = null;
        try
        {
            if (options.TestRoot is not null) throw new IOException("隔离实例请使用更新测试程序。");
            Directory.CreateDirectory(work);
            if (new DriveInfo(Path.GetPathRoot(work)!).AvailableFreeSpace < 5L * 1024 * 1024 * 1024) throw new IOException("磁盘空间不足，请至少留出 5 GB。");
            var asset = SignedUpdate.Asset(newer.Version, ReleaseVersion, "windows-x64");
            var zip = Path.Combine(work, "update.zip"); var sig = Path.Combine(work, "update.sig");
            updateMessage = "正在下载更新签名…";
            await SignedUpdate.Download(new Uri(asset.AbsoluteUri + ".sig"), sig, 16384, _ => {}, cancellation.Token);
            await SignedUpdate.Download(asset, zip, SignedUpdate.MaxArchive, p => Application.Current.Dispatcher.BeginInvoke(() => updateMessage = p < 0 ? "正在下载更新…" : $"正在下载更新 {(int)(p*100)}%"), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested(); updateMessage = "正在验证并准备安装…";
            var target = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
            var request = await Task.Run(() => SignedUpdate.Prepare(zip, sig, target, newer.Version, ReleaseVersion, work));
            staged = System.Text.Json.JsonSerializer.Deserialize<SignedUpdate.Request>(File.ReadAllText(request))!.Staged;
            cancellation.Token.ThrowIfCancellationRequested();
            // A temporary copy of the existing self-contained app is the helper. Never runs inside the folder being moved.
            var helper = Path.Combine(work, "helper");
            await Task.Run(() => {
                foreach (var source in Directory.EnumerateFiles(target, "*", SearchOption.AllDirectories)) {
                    cancellation.Token.ThrowIfCancellationRequested();
                    var destination = Path.Combine(helper, Path.GetRelativePath(target, source));
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!); File.Copy(source, destination);
                }
            });
            cancellation.Token.ThrowIfCancellationRequested();
            var info = new ProcessStartInfo(Path.Combine(helper, "Sakura.exe")) { UseShellExecute = false, WorkingDirectory = helper };
            info.ArgumentList.Add("--apply-update"); info.ArgumentList.Add(request); Process.Start(info);
            Application.Current.Shutdown();
        }
        catch (Exception e)
        {
            try { if (staged is not null && Directory.Exists(staged)) Directory.Delete(staged, true); if (Directory.Exists(work)) Directory.Delete(work, true); } catch { }
            updateMessage = cancellation.IsCancellationRequested ? "下载已取消，旧版仍可使用。" : $"更新失败：{e.Message} 可去 GitHub 手动下载。";
            if (!cancellation.IsCancellationRequested && MessageBox.Show(updateMessage + "\n\n去 GitHub 手动下载？", "更新失败", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes) OpenUpdateFallback();
        }
        finally { installCancellation = null; }
    }
    private void ToggleAutoUpdate() => SetAutomaticUpdates(!AutoUpdateEnabled);
    public void SetAutomaticUpdates(bool value)
    {
        settings.AutoCheckUpdates = value;
        SaveSettings();
        log.Write($"auto-update-check enabled={AutoUpdateEnabled.ToString().ToLowerInvariant()}");
    }

    private void OpenUpdatePage(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) return;
        try { Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { log.Write($"update-open-failed type={e.GetType().Name}"); }
    }

    private IReadOnlyList<TrayEntry> BuildMenu()
    {
        if (!libraryBusy) ReloadPacks();
        bool login = false;
        try { login = LoginStartup.IsEnabled(); }
        catch (Exception e) when (e is SecurityException or UnauthorizedAccessException or IOException)
        { log.Write("login-read-failed"); }
        var snooze = playState.ActiveSnooze(UnixNow());
        var shown = !settings.Paused && player is null && snooze is { } until
            ? $"自动播放已暂停到 {DateTimeOffset.FromUnixTimeMilliseconds((long)(until * 1000)).ToLocalTime():HH:mm}" : status;
        var hour = experience.Playback.DayStartHour;
        var snoozeEntries = new List<TrayEntry>
        {
            new("暂停 1 小时", () => Snooze(UnixNow() + 3600), !settings.Paused),
            new($"暂停到明天 {hour}:00", () => { var now = UnixNow(); Snooze(ScheduleDecision.NextDayStart(now, Offset(now), hour)); }, !settings.Paused),
        };
        if (snooze is not null) snoozeEntries.Add(new("恢复自动播放", () => Snooze(null)));
        var update = AvailableUpdate();
        return [
            new("Sakura", Enabled: false),
            .. (update is { } u ? new[] { new TrayEntry(installCancellation is null ? $"有新版本 {u.Version} · 更新…" : updateMessage + " · 取消下载", OpenUpdateDownload), new TrayEntry("在 GitHub 查看", OpenUpdateFallback) } : []),
            new(shown, Enabled: false),
            new($"当前动画：{activePack?.Manifest.Name ?? "无"}", Enabled: false), new(Separator: true),
            new("调节启动体验…", OpenSettings, !libraryBusy && activePack is not null),
            new("预览当前动画", () => { log.Write("preview-requested"); Play(true); }, !libraryBusy && activePack is not null),
            new("导入动画包…", () => _ = ImportPack(), !libraryBusy),
            new("切换动画", Enabled: !libraryBusy && packs.Count > 0,
                Children: packs.Select(p => new TrayEntry(p.Manifest.Name, () => SelectPack(p.Id),
                    !libraryBusy, p.Id == activePack?.Id)).ToArray()),
            new(Separator: true),
            new("暂停自动播放", TogglePause, Checked: settings.Paused),
            .. snoozeEntries,
            new("关闭动画时仍播放", () => { settings.PlayDespiteReduceMotion = !settings.PlayDespiteReduceMotion; SaveSettings(); },
                Checked: settings.PlayDespiteReduceMotion),
            new(Separator: true),
            new("开机自动运行", () => ToggleLogin(!login), Enabled: options.TestRoot is null && options.TestTargetExe is null, Checked: login),
            new("检查更新…", () => _ = CheckForUpdates(manual: true)),
            new("自动检查更新", ToggleAutoUpdate, Checked: AutoUpdateEnabled),
            new("打开日志", OpenLog), new(Separator: true), new("退出 Sakura", () => { if (experienceWindow?.RequestClose() != false) Application.Current.Shutdown(); }),
        ];
    }

    private void SelectPack(string id)
    {
        player?.Send(new PlaybackEvent.Superseded());
        settings.ActivePackId = id;
        SaveSettings();
        ReloadPacks();
        RefreshWindow();
    }

    private LibraryView View() => new(packs, problemList, activePack?.Id, BundledId, playState, CacheRoot) { Testing = compat?.Id };

    private void RefreshWindow()
    {
        if (experienceWindow is { IsVisible: true } window) window.UpdateLibrary(View());
    }

    private void Snooze(double? until)
    {
        playState.SnoozeUntil = until;
        SaveState();
        if (until is not null && player is { IsPreview: false }) player.Send(new PlaybackEvent.Skip());
        log.Write(until is { } u ? FormattableString.Invariant($"snoozed until={u:F0}") : "snooze-cleared");
    }

    void ILibraryActions.SetActive(string id) => SelectPack(id);
    void ILibraryActions.Import() => _ = ImportPack();
    void ILibraryActions.CreateFromVideo() => _ = CreateFromVideo();

    /// <summary>"从视频创建动画" (launcher-spec/PACK-FROM-VIDEO.md). <paramref name="testVideo"/> skips the dialogs.</summary>
    private async Task CreateFromVideo(string? testVideo = null)
    {
        if (libraryBusy) return;
        player?.Send(new PlaybackEvent.Superseded());
        string video, name;
        if (testVideo is null)
        {
            var open = new Microsoft.Win32.OpenFileDialog { Title = "选择一个视频", Filter = "视频 (*.mp4;*.m4v;*.mov)|*.mp4;*.m4v;*.mov", Multiselect = false };
            if (open.ShowDialog(experienceWindow) != true) return;
            video = open.FileName;
            if (VideoPackRules.Extension(Path.GetFileName(video)) is null)
            { MessageBox.Show("请选择 mp4、m4v 或 mov 视频。", "从视频创建动画", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            var dialog = new VideoPackDialog(Path.GetFileName(video));
            if (experienceWindow is { IsVisible: true }) dialog.Owner = experienceWindow;
            if (dialog.ShowDialog() != true) return;
            name = dialog.PackName;
        }
        else { video = testVideo; name = VideoPackRules.DefaultName(Path.GetFileName(testVideo)); }
        warmClip?.Dispose();
        warmClip = null;
        libraryBusy = true;
        status = "正在检查视频…";
        RefreshWindow();
        var staging = Path.Combine(library.Root, ".video-" + Guid.NewGuid().ToString("N"));
        try
        {
            var existing = packs.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
            var folder = await Task.Run(() => VideoPackRules.Build(video, name, existing, staging, DateTime.Now, () => (uint)Random.Shared.NextInt64(0, 1L << 32)));
            var created = await library.ImportPack(folder, Probe, ImageProbe);
            if (disposed) return;
            settings.ActivePackId = created.Id;
            SaveSettings();
            ReloadPacks();
            status = $"已创建「{created.Manifest.Name}」。可在“声音与过渡”里调整淡出起点。";
            log.Write($"pack-created-from-video id={created.Id}");
        }
        catch (Exception e) when (e is PackException or IOException or UnauthorizedAccessException or OperationCanceledException or ArgumentException)
        {
            if (disposed) return;
            status = "创建失败，动画库未改变";
            log.Write($"pack-create-failed type={e.GetType().Name}");
            if (testVideo is null) MessageBox.Show(e.Message, "无法用这个视频创建动画", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            libraryBusy = false;
            Rewarm();
            RefreshWindow();
        }
    }
    void ILibraryActions.ResetToday()
    {
        foreach (var target in playState.Targets.Values) target.LastAutoPlayAt = null;
        SaveState();
        log.Write("played-today-cleared");
        RefreshWindow();
    }

    void ILibraryActions.Remove(InstalledPack pack)
    {
        if (libraryBusy) return;
        player?.Send(new PlaybackEvent.Superseded());
        warmClip?.Dispose();
        warmClip = null;
        try
        {
            library.Remove(pack.Id, BundledId, directory => Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(directory,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin));
            log.Write($"pack-removed id={pack.Id}");
            status = $"已将「{pack.Manifest.Name}」移到回收站";
        }
        catch (Exception e) when (e is PackException or IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            log.Write($"pack-remove-failed type={e.GetType().Name}");
            MessageBox.Show(e.Message, "移除动画失败", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        ReloadPacks();
        RefreshWindow();
    }

    private async Task ImportPack()
    {
        if (libraryBusy) return;
        player?.Send(new PlaybackEvent.Superseded());
        var dialog = new OpenFolderDialog { Title = "选择动画包文件夹", Multiselect = false };
        if (dialog.ShowDialog() != true) return;
        // Release the warm decoder first: an open media file would block replacing that pack's folder.
        warmClip?.Dispose();
        warmClip = null;
        libraryBusy = true;
        status = "正在检查动画包…";
        try
        {
            var imported = await library.ImportPack(dialog.FolderName, Probe, ImageProbe);
            if (disposed) return;
            settings.ActivePackId = imported.Id;
            SaveSettings();
            ReloadPacks();
            RefreshWindow();
            status = "动画已更新，可以预览";
            log.Write($"pack-imported id={imported.Id}");
        }
        catch (Exception e) when (e is PackException or IOException or UnauthorizedAccessException or OperationCanceledException or ArgumentException)
        {
            if (disposed) return;
            status = "导入失败，已保留原包";
            log.Write($"pack-import-failed type={e.GetType().Name}");
            MessageBox.Show(e.Message, "导入动画包失败", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { libraryBusy = false; Rewarm(); }
    }

    private bool showWhenReady;

    /// <summary>Another copy was started by hand: bring the settings to the front (after first-run setup if still busy).</summary>
    public void ShowSettings()
    {
        log.Write("reopen-requested");
        if (libraryBusy) { showWhenReady = true; return; }
        OpenSettings();
        if (experienceWindow is { } window)
        {
            if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
            window.Activate(); window.Topmost = true; window.Topmost = false; window.Focus();
        }
    }

    public bool WelcomeDismissed => settings.WelcomeDismissed;
    public void SetWelcomeDismissed(bool value)
    {
        var previous = settings.WelcomeDismissed;
        settings.WelcomeDismissed = value;
        try { settings.Save(options.DataRoot); }
        catch { settings.WelcomeDismissed = previous; throw; }
    }
    public OverviewSnapshot Overview(string? targetId)
    {
        IReadOnlyList<LaunchTarget> configured = options.TestTargetExe is { } test
            ? [new() { Id = "test", Name = "测试应用", Enabled = true, Windows = new() { Path = test } }]
            : experience.Targets.Where(t => t.Windows is not null).ToList();
        var selected = configured.FirstOrDefault(t => t.Id == targetId) ?? configured.FirstOrDefault();
        var input = new PlaybackStatusInput
        {
            Preparing = libraryBusy, Playing = player is not null, Preview = player is { IsPreview: true },
            HasTarget = selected is not null, TargetEnabled = selected?.Enabled ?? false,
            Paused = settings.Paused, ReduceMotion = TargetMonitor.ReduceMotion, AllowMotion = settings.PlayDespiteReduceMotion,
            LoginGrace = options.TestRoot is null && LaunchFilter.Skip(false, lifetime.Elapsed.TotalSeconds, options.AtLogin, Environment.TickCount64 / 1000.0) is not null,
        };
        if (selected is not null)
        {
            var processes = monitor.SessionOf(selected.Id).Processes;
            input.Running = processes.Count > 0;
            input.Hidden = input.Running && TargetMonitor.IsHidden(processes);
            var mine = playState.For(selected.Id); var now = UnixNow();
            var schedule = ScheduleDecision.Decide(experience.Playback.Frequency, experience.Playback.DayStartHour,
                mine, now, Offset(now), mine.LastAutoPlayAt is { } last ? Offset(last) : Offset(now));
            input.Snoozed = schedule == ScheduleOutcome.Snoozed; input.PlayedToday = schedule == ScheduleOutcome.PlayedToday;
            var chosen = packs.FirstOrDefault(p => p.Id == selected.Animation) ?? activePack;
            input.HasPack = chosen is not null && chosen.Manifest.Segments.Values.All(file => File.Exists(Path.Combine(chosen.Directory, file)));
            input.Failed = chosen is not null && (failedOverviewPacks.GetValueOrDefault(selected.Id) == chosen.Id || failedOverviewPacks.GetValueOrDefault("preview") == chosen.Id);
        }
        return new(configured.Select(t => new OverviewTarget(t.Id, t.Name)).ToList(), selected?.Id, PlaybackStatusReason.Resolve(input));
    }
    public void PerformOverviewAction(string action)
    {
        if (action == "unpause")
        {
            var previous = settings.Paused; settings.Paused = false;
            try { settings.Save(options.DataRoot); }
            catch { settings.Paused = previous; throw; }
        }
        if (action == "unsnooze")
        {
            var previous = playState.SnoozeUntil; playState.SnoozeUntil = null;
            try { stateStore.Save(playState); }
            catch { playState.SnoozeUntil = previous; throw; }
        }
        status = settings.Paused ? "自动播放已暂停" : Waiting();
    }

    private void OpenSettings()
    {
        if (libraryBusy) return;
        var pack = activePack;
        showWhenReady = false;
        if (experienceWindow is { IsVisible: true } current) { current.Activate(); return; }
        player?.Send(new PlaybackEvent.Superseded());
        experienceWindow = new ExperienceWindow(pack, experience, experienceWarning,
            document =>
            {
                experienceStore.Save(document); experience = document.Copy(); experienceWarning = ""; log.Write("experience-saved");
                monitor.Configure(WatchedTargets());
                log.Write($"targets-configured targets={string.Join(",", monitor.TargetIds)}");
            },
            (document, target) => Play(true, document, target), View(), this, this);
        experienceWindow.Show();
        experienceWindow.Activate();
        log.Write($"settings-opened pack={pack?.Id ?? "none"}");
    }

    private void TogglePause()
    {
        settings.Paused = !settings.Paused;
        SaveSettings();
        if (settings.Paused) player?.Send(new PlaybackEvent.Skip());
        status = settings.Paused ? "自动播放已暂停" : Waiting();
    }

    private void SaveSettings()
    {
        try { settings.Save(options.DataRoot); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { status = "设置未保存，请检查数据目录权限"; log.Write("settings-save-failed"); }
    }

    private void ToggleLogin(bool enabled)
    {
        try { LoginStartup.SetEnabled(enabled); }
        catch (Exception e) when (e is IOException or SecurityException or UnauthorizedAccessException)
        { status = "开机自动运行未更新"; log.Write($"login-update-error type={e.GetType().Name}"); }
    }

    private void OpenLog()
    {
        try
        {
            log.Write("log-opened");
            Process.Start(new ProcessStartInfo(log.Path) { UseShellExecute = true });
        }
        catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception)
        { status = "无法打开日志文件"; }
    }

    private void PowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode != PowerModes.Resume) return;
        Application.Current.Dispatcher.BeginInvoke(() => { warmClip?.Dispose(); warmClip = null; Rewarm(); log.Write("rewarmed-after-resume"); });
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        updateTimer?.Stop();
        SystemEvents.PowerModeChanged -= PowerModeChanged;
        warmClip?.Dispose();
        warmClip = null;
        generation = Guid.NewGuid();
        player?.Send(new PlaybackEvent.Superseded());
        player = null;
        shutdown.Cancel();
        installCancellation?.Cancel();
        monitor.Dispose();
        tray.Dispose();
    }
}
