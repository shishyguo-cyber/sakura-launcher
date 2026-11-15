using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>What the library section shows. Immediate actions go through <see cref="ILibraryActions"/>.</summary>
internal sealed record LibraryView(IReadOnlyList<InstalledPack> Packs, IReadOnlyDictionary<string, string> Problems,
                                   string? ActiveId, string BundledId, PlaybackState State, string CacheRoot)
{
    /// <summary>The target whose "测试一下" is running, if any.</summary>
    public string? Testing { get; init; }
}

/// <summary>Library operations that take effect at once and never touch the settings draft.</summary>
internal interface ILibraryActions
{
    void SetActive(string id);
    void Remove(InstalledPack pack);
    void Import();
    void CreateFromVideo();
    void ResetToday();
    void TestTarget(string id);
}

/// <summary>
/// Settings window, design v2 "花园清新" (launcher-spec/DESIGN.md): left navigation with seven pages and a mint status/preview
/// header, grouped lists. Edits a private draft; preview, save and cancellation have separate paths.
/// </summary>
internal sealed partial class ExperienceWindow : Window
{
    private InstalledPack? pack;
    private ExperienceSettings draft;
    private readonly Action<ExperienceSettings> save;
    private readonly Action<ExperienceSettings, InstalledPack> preview;
    private LibraryView? library;
    private readonly ILibraryActions? actions;
    private bool loading, dirty, closed, justSaved;

    private readonly Dictionary<string, FrameworkElement> pages = new();
    private readonly Dictionary<string, RadioButton> nav = new();
    private readonly UniformGrid cards = new() { Columns = 3 };
    private readonly StackPanel targetRows = new();
    /// <summary>Source of the "添加应用" list; tests substitute their own.</summary>
    internal Func<Task<IReadOnlyList<InstalledApp>>> InstalledAppsProvider { get; set; } = InstalledApps.LoadAsync;
    private readonly StackPanel problemsPanel = new();
    private readonly ComboBox rotation = new() { MinWidth = 200 };
    private readonly RadioButton everyLaunch = new() { Content = "每次启动", GroupName = "frequency" };
    private readonly RadioButton firstOfDay = new() { Content = "每天首次", GroupName = "frequency" };
    private readonly ComboBox dayStart = new() { Width = 96 };
    private readonly FrameworkElement[] dayRows = new FrameworkElement[2];
    private readonly TextBlock today = Text("", 12);
    private readonly TextBlock status = Text("", 12);
    private readonly TextBlock savedLabel = Text("当前设置", 12);
    private readonly Slider volume = new() { Minimum = 0, Maximum = 1, TickFrequency = .01, IsSnapToTickEnabled = true, Width = 200 };
    private readonly TextBlock volumeValue = Value("100%");
    private readonly CheckBox muted = new() { Content = "静音" };
    private readonly CheckBox quiet = new() { Content = "" };
    private readonly CheckBox customHandoff = new() { Content = "自定义" };
    private readonly TextBox handoff = new() { Width = 96 };
    private readonly TextBlock handoffDefault = Secondary("");
    private readonly ComboBox loop = new() { MinWidth = 180 };
    private readonly CheckBox customLoop = new() { Content = "自定义" };
    private readonly TextBlock loopDefault = Secondary("");
    private static readonly Dictionary<string, double?> Durations = new(); // header reads, per file version
    private readonly ComboBox fitMode = new() { MinWidth = 220 };
    private readonly ComboBox presets = new() { MinWidth = 180, DisplayMemberPath = "Name" };
    private readonly TextBox presetName = new() { MinWidth = 180 };
    private readonly OverrideSlider fade, wait, coverage;
    private readonly TextBlock statFade = Stat(), statWait = Stat(), statLoop = Stat();
    private readonly Border heroCover = new() { Width = 185, Height = 104, CornerRadius = new(8), ClipToBounds = true };
    private readonly TextBlock heroName = Text("", 18), heroMeta = Text("", 12);
    private readonly Image brand = new() { Width = 18, Height = 18, Margin = new(0, 0, 8, 0) };
    public string? PackId => pack?.Id;

    public ExperienceWindow(InstalledPack? pack, ExperienceSettings settings, string warning,
                            Action<ExperienceSettings> onSave, Action<ExperienceSettings> onPreview)
        : this(pack, settings, warning, onSave, (d, _) => onPreview(d), null, null) { }

    public ExperienceWindow(InstalledPack? initial, ExperienceSettings settings, string warning, Action<ExperienceSettings> onSave,
                            Action<ExperienceSettings, InstalledPack> onPreview, LibraryView? view, ILibraryActions? libraryActions, IOverviewRuntime? runtime = null)
    {
        this.runtime = runtime; welcomeDismissed = runtime?.WelcomeDismissed ?? false;
        pack = initial; draft = settings.Copy(); save = onSave; preview = onPreview; library = view; actions = libraryActions;
        Theme.Apply(Resources, Theme.AppsDark);
        Title = "Sakura"; Width = 960; Height = Math.Min(640, SystemParameters.WorkArea.Height - 32);
        MinWidth = 820; MinHeight = 560; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Segoe UI Variable Text, Microsoft YaHei UI"); FontSize = 13;
        SetResourceReference(BackgroundProperty, "Bg"); SetResourceReference(ForegroundProperty, "Text");
        fade = new("淡出时长", .1, 2, .1, initial?.Manifest.EffectiveFadeDuration ?? .3, Changed);
        wait = new("最长等待", 1, 60, 1, initial?.Manifest.EffectiveMaxWait ?? 8, Changed);
        coverage = new("开场尺寸", .4, .9, .01, .72, Changed, true);

        var root = new Grid();
        root.ColumnDefinitions.Add(new() { Width = new(180) }); root.ColumnDefinitions.Add(new());
        root.Children.Add(BuildNav());
        var main = new DockPanel { Margin = new(24, 20, 16, 0) };
        var hero = BuildHero(); overviewHero = hero; DockPanel.SetDock(hero, Dock.Top); main.Children.Add(hero);
        var host = new Grid { Margin = new(0, 16, 8, 24) };
        foreach (var (key, page) in new (string, FrameworkElement)[] {
            ("overview", BuildOverviewPage()), ("animation", BuildAnimationPage()), ("targets", BuildTargetsPage()), ("playback", BuildPlaybackPage()), ("sound", BuildSoundPage()),
            ("display", BuildDisplayPage()), ("presets", BuildPresetsPage()) })
        { pages[key] = page; host.Children.Add(page); }
        main.Children.Add(new ScrollViewer { Content = host, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                                             HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Tag = "content" });
        Grid.SetColumn(main, 1); root.Children.Add(main);
        Content = root;

        System.Windows.Automation.AutomationProperties.SetName(handoff, "淡出起点秒数");
        System.Windows.Automation.AutomationProperties.SetName(customHandoff, "自定义淡出起点");
        System.Windows.Automation.AutomationProperties.SetName(volume, "总音量");
        System.Windows.Automation.AutomationProperties.SetName(presetName, "方案名称");
        ShowPack(); LoadControls(); BuildCards(); BuildTargets(); SetPill(); ShowPage("overview"); RefreshOverview();
        if (warning.Length > 0) status.Text = warning;
        Closing += ConfirmClose;
        void OnTheme() { Theme.Apply(Resources, Theme.AppsDark); Theme.UseDarkTitleBar(this, Theme.AppsDark); PaintBrand(); BuildCards(); ShowPack(); SetPill(); }
        SourceInitialized += (_, _) => Theme.UseDarkTitleBar(this, Theme.AppsDark);
        Theme.Changed += OnTheme;
        Closed += (_, _) => { closed = true; Theme.Changed -= OnTheme; };
        Bind(System.Windows.Input.Key.S, () => TrySave());
        Bind(System.Windows.Input.Key.P, TryPreview);
    }

    // ---------- layout ----------

    private FrameworkElement BuildNav()
    {
        var panel = new DockPanel { Margin = new(12, 18, 12, 16) };
        var brandRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new(10, 0, 0, 18) };
        PaintBrand();
        brandRow.Children.Add(brand);
        var name = Text("Sakura", 13); name.FontWeight = FontWeights.SemiBold; name.VerticalAlignment = VerticalAlignment.Center; brandRow.Children.Add(name);
        DockPanel.SetDock(brandRow, Dock.Top); panel.Children.Add(brandRow);

        var bottom = new StackPanel();
        savedLabel.Margin = new(10, 0, 0, 6); bottom.Children.Add(savedLabel);
        status.Margin = new(10, 0, 0, 10); status.MaxHeight = 54; bottom.Children.Add(status);
        var saveButton = Button("保存设置", () => TrySave(), "PrimaryButton"); saveButton.HorizontalAlignment = HorizontalAlignment.Stretch;
        saveButton.ToolTip = "Ctrl+S"; bottom.Children.Add(saveButton);
        DockPanel.SetDock(bottom, Dock.Bottom); panel.Children.Add(bottom);

        var items = new StackPanel();
        foreach (var (key, label, glyph) in new[] { ("overview", "概览", "\uE80F"), ("animation", "动画", ""), ("targets", "应用", "\uE71D"), ("playback", "播放", ""), ("sound", "声音与过渡", ""),
                                                     ("display", "显示", ""), ("presets", "我的方案", "") })
        {
            var item = new RadioButton { Content = label, Tag = glyph, GroupName = "nav" };
            item.SetResourceReference(StyleProperty, "NavItem");
            System.Windows.Automation.AutomationProperties.SetName(item, "页面 " + label);
            item.Checked += (_, _) => ShowPage(key);
            nav[key] = item; items.Children.Add(item);
        }
        panel.Children.Add(items);
        var border = new Border { Child = panel, BorderThickness = new(0, 0, 1, 0) };
        border.SetResourceReference(Border.BackgroundProperty, "Sidebar");
        border.SetResourceReference(Border.BorderBrushProperty, "Divider");
        return border;
    }

    private void PaintBrand() => brand.Source = FlowerIcon.Render(72, Theme.Token("AccentFill", Theme.AppsDark));

    private FrameworkElement BuildHero()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new());
        grid.Children.Add(heroCover);
        var info = new DockPanel { Margin = new(16, 2, 0, 0) };
        var previewButton = Button("▶  预览", TryPreview, "PillButton");
        previewButton.ToolTip = "预览未保存的调整（Ctrl+P）";
        System.Windows.Automation.AutomationProperties.SetName(previewButton, "预览当前调整");
        previewButton.HorizontalAlignment = HorizontalAlignment.Right; previewButton.VerticalAlignment = VerticalAlignment.Bottom;
        DockPanel.SetDock(previewButton, Dock.Bottom); info.Children.Add(previewButton);
        var titles = new StackPanel();
        heroName.FontWeight = FontWeights.SemiBold; heroName.SetResourceReference(TextBlock.ForegroundProperty, "HeroText"); titles.Children.Add(heroName);
        heroMeta.SetResourceReference(TextBlock.ForegroundProperty, "HeroSecondary"); heroMeta.Margin = new(0, 4, 0, 0); titles.Children.Add(heroMeta);
        info.Children.Add(titles);
        Grid.SetColumn(info, 1); grid.Children.Add(info);
        var hero = new Border { CornerRadius = new(14), Padding = new(16), Height = 136, Child = grid };
        hero.SetResourceReference(Border.BackgroundProperty, "Hero");
        return hero;
    }

    private FrameworkElement BuildAnimationPage()
    {
        var page = new StackPanel();
        var row = new DockPanel { Margin = new(0, 0, 0, 12) };
        rotation.ItemsSource = new[] { "固定播放当前动画", "全部动画随机", "收藏动画随机" };
        System.Windows.Automation.AutomationProperties.SetName(rotation, "轮换方式");
        rotation.SelectionChanged += (_, _) => { Changed(); ShowPack(); };
        DockPanel.SetDock(rotation, Dock.Right); row.Children.Add(rotation);
        var label = Text("自动播放时"); label.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(label);
        page.Children.Add(row);
        cards.Margin = new(-6, 0, -6, 0); page.Children.Add(cards);
        problemsPanel.Margin = new(0, 8, 0, 0); page.Children.Add(problemsPanel);
        return page;
    }

    private FrameworkElement BuildTargetsPage()
    {
        var page = new StackPanel();
        var card = new Border { Child = targetRows }; card.SetResourceReference(StyleProperty, "Card");
        page.Children.Add(card);
        page.Children.Add(Hint("同一时间只播放一个动画；正在播放时打开的其他应用不再播放。"));
        return page;
    }

    /// <summary>Rows for the targets this machine can watch; targets that only carry another platform's identity stay hidden.</summary>
    private void BuildTargets()
    {
        targetRows.Children.Clear();
        var packList = library?.Packs ?? (pack is null ? [] : [pack]);
        foreach (var target in draft.Targets.Where(t => t.Windows is not null))
        {
            var right = new StackPanel { Orientation = Orientation.Horizontal };
            var choice = new ComboBox { MinWidth = 170, Margin = new(0, 0, 12, 0) };
            var options = new List<(string? Id, string Label)> { (null, "跟随全局轮换") };
            options.AddRange(packList.Select(p => ((string?)p.Id, p.Manifest.Name)));
            if (target.Animation is { } bound && options.All(o => o.Id != bound)) options.Add((bound, "（已移除的动画）"));
            choice.ItemsSource = options.Select(o => o.Label).ToList();
            choice.SelectedIndex = options.FindIndex(o => o.Id == target.Animation);
            System.Windows.Automation.AutomationProperties.SetName(choice, "动画 " + target.Id);
            choice.SelectionChanged += (_, _) => Guard(() =>
            {
                if (choice.SelectedIndex < 0) return;
                draft = ReadDraft(); draft.Targets.First(t => t.Id == target.Id).Animation = options[choice.SelectedIndex].Id; Changed();
            });
            right.Children.Add(choice);
            var enabled = new CheckBox { Content = "", IsChecked = target.Enabled, VerticalAlignment = VerticalAlignment.Center, Margin = new(0, 0, 8, 0) };
            System.Windows.Automation.AutomationProperties.SetName(enabled, "启用 " + target.Id);
            enabled.Click += (_, _) => Guard(() => { draft = ReadDraft(); draft.Targets.First(t => t.Id == target.Id).Enabled = enabled.IsChecked == true; BuildTargets(); Changed(); });
            right.Children.Add(enabled);
            if (actions is not null)
            {
                var testing = library?.Testing == target.Id;
                var test = Small(testing ? "测试中…" : "测试", () => actions.TestTarget(target.Id), "测试应用 " + target.Id);
                test.IsEnabled = !testing; test.ToolTip = "在 30 秒内打开这个应用，检查 Sakura 能否正确识别它";
                right.Children.Add(test);
            }
            right.Children.Add(Small("移除", () => Guard(() =>
            {
                draft = ReadDraft(); draft.Targets.RemoveAll(t => t.Id == target.Id); BuildTargets(); Changed();
                status.Text = $"已从草稿移除「{target.Name}」，保存后生效。";
            }), "移除应用 " + target.Id, "DangerTextButton"));
            var label = new StackPanel { Orientation = Orientation.Horizontal };
            var icon = new Border { Width = 24, Height = 24, CornerRadius = new(6), Margin = new(0, 0, 10, 0), ClipToBounds = true };
            icon.SetResourceReference(Border.BackgroundProperty, "AccentSoft");
            icon.Child = InstalledApps.IconFor(target.Windows!) is { } source
                ? new Image { Source = source, Width = 24, Height = 24 }
                : new TextBlock { Text = target.Name[..1], HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
            label.Children.Add(icon);
            var name = Text(target.Name); name.TextWrapping = TextWrapping.NoWrap; name.TextTrimming = TextTrimming.CharacterEllipsis;
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(name);
            var detailLine = new WrapPanel();
            var compat = library?.State.Targets.GetValueOrDefault(target.Id)?.Compat;
            if (library?.Testing == target.Id) detailLine.Children.Add(Secondary($"请在 30 秒内打开 {target.Name}；如果它正在运行，请先完全退出"));
            else if (compat is { } result)
            {
                var line = Secondary(CompatibilityRules.Message(result.Verdict, result.WindowSeconds));
                if (result.Verdict == CompatVerdict.Good) line.SetResourceReference(TextBlock.ForegroundProperty, "Success");
                detailLine.Children.Add(line);
            }
            var reappearToggle = Small(target.PlayOnReappear ? "已开启：窗口重新出现时也播放 · 关闭" : "窗口重新出现时也播放", () => Guard(() =>
            {
                draft = ReadDraft(); var t = draft.Targets.First(x => x.Id == target.Id); t.PlayOnReappear = !t.PlayOnReappear; BuildTargets(); Changed();
            }), "重新出现 " + target.Id);
            if (target.PlayOnReappear || compat?.Verdict == CompatVerdict.AlreadyRunning) { reappearToggle.Margin = new(-6, 0, 0, 0); detailLine.Children.Add(reappearToggle); }
            if (detailLine.Children.Count > 0) texts.Children.Add(detailLine);
            label.Children.Add(texts);
            if (!target.Enabled) label.Opacity = 0.55;
            AddRow(targetRows, label, right);
        }
        var add = Button("\uFF0B  添加应用", OpenPicker, "TextButton");
        add.HorizontalAlignment = HorizontalAlignment.Left; add.Height = 40;
        AddView(targetRows, add);
    }

    private void OpenPicker()
    {
        var picker = new AppPickerWindow(InstalledAppsProvider, draft.Targets.Where(t => t.Windows is not null).SelectMany(t => InstalledApps.AddedKeys(t.Windows!)).ToHashSet(),
            app => Guard(() =>
            {
                var next = ReadDraft();
                var name = new System.Globalization.StringInfo(app.Name.Trim());
                next.Targets.Add(new LaunchTarget
                {
                    Id = Guid.NewGuid().ToString(), Name = name.LengthInTextElements > 40 ? name.SubstringByTextElements(0, 40).Trim() : name.String,
                    Enabled = true, Windows = app.Identity,
                });
                next.Validate();
                draft = next; BuildTargets(); Changed();
                status.Text = $"已添加「{app.Name}」，保存后开始监听。";
            })) { Owner = IsLoaded ? this : null };
        Theme.Apply(picker.Resources, Theme.AppsDark);
        picker.Show();
    }

    private FrameworkElement BuildPlaybackPage()
    {
        var page = new StackPanel();
        var list = Group(page);
        var segments = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var option in new[] { everyLaunch, firstOfDay }) { option.SetResourceReference(StyleProperty, "Segment"); segments.Children.Add(option); }
        var box = new Border { Child = segments }; box.SetResourceReference(StyleProperty, "Segments");
        AddRow(list, "播放频率", box);
        System.Windows.Automation.AutomationProperties.SetName(quiet, "全屏或演示时不播放");
        quiet.Checked += (_, _) => Changed(); quiet.Unchecked += (_, _) => Changed();
        var quietRow = AddRow(list, "全屏或演示时不播放", quiet);
        quietRow.ToolTip = "看视频、玩游戏或演示时打开应用，不弹出动画。系统勿扰和屏幕共享目前无法可靠检测。";
        dayStart.ItemsSource = Enumerable.Range(0, 24).Select(h => $"{h}:00").ToArray();
        System.Windows.Automation.AutomationProperties.SetName(dayStart, "新的一天开始时间");
        dayStart.SelectionChanged += (_, _) => { Changed(); UpdateToday(); };
        dayStart.ToolTip = "这个时间之前打开，仍算前一天。";
        dayRows[0] = AddRow(list, "新的一天从", dayStart);
        var again = actions is null ? null : Button("下次启动照常播放", () => actions.ResetToday(), "TextButton");
        today.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        dayRows[1] = AddRow(list, today, again);
        everyLaunch.Checked += (_, _) => { ShowDayRows(); Changed(); };
        firstOfDay.Checked += (_, _) => { ShowDayRows(); Changed(); UpdateToday(); };
        page.Children.Add(Hint("临时暂停在托盘菜单里，立即生效。"));
        return page;
    }

    private FrameworkElement BuildSoundPage()
    {
        var page = new StackPanel();
        var stats = new UniformGrid { Columns = 3, Margin = new(-6, 0, -6, 10) };
        foreach (var (label, value) in new[] { ("淡出", statFade), ("最长等待", statWait), ("窗口就绪时", statLoop) })
        {
            var body = new StackPanel(); body.Children.Add(Secondary(label)); value.Margin = new(0, 4, 0, 0); body.Children.Add(value);
            var tile = new Border { Child = body, Padding = new(12), Margin = new(6), CornerRadius = new(12), BorderThickness = new(1) };
            tile.SetResourceReference(Border.BackgroundProperty, "Surface"); tile.SetResourceReference(Border.BorderBrushProperty, "Border");
            stats.Children.Add(tile);
        }
        page.Children.Add(stats);
        var list = Group(page);
        var volumeRow = new StackPanel { Orientation = Orientation.Horizontal };
        volume.VerticalAlignment = VerticalAlignment.Center; volumeRow.Children.Add(volume);
        volumeValue.Margin = new(8, 0, 16, 0); volumeRow.Children.Add(volumeValue);
        muted.VerticalAlignment = VerticalAlignment.Center; volumeRow.Children.Add(muted);
        var resetVolume = Button("恢复音量", () => { volume.Value = 1; muted.IsChecked = false; }, "TextButton"); resetVolume.Margin = new(10, 0, 0, 0);
        volumeRow.Children.Add(resetVolume);
        AddRow(list, "总音量", volumeRow);
        volume.ValueChanged += (_, _) => { volumeValue.Text = $"{volume.Value:P0}"; Changed(); };
        muted.Checked += (_, _) => { volume.IsEnabled = false; Changed(); }; muted.Unchecked += (_, _) => { volume.IsEnabled = true; Changed(); };
        AddView(list, fade.View);
        var handoffRight = new StackPanel { Orientation = Orientation.Horizontal };
        handoffDefault.VerticalAlignment = VerticalAlignment.Center; handoffDefault.Margin = new(0, 0, 10, 0); handoffRight.Children.Add(handoffDefault);
        handoff.Margin = new(0, 0, 10, 0); handoffRight.Children.Add(handoff); handoffRight.Children.Add(customHandoff);
        var handoffRow = AddRow(list, "淡出起点", handoffRight);
        handoffRow.ToolTip = "按秒填写；超出片段时长会自动收紧。";
        customHandoff.Checked += (_, _) => { ShowHandoff(); Changed(); }; customHandoff.Unchecked += (_, _) => { ShowHandoff(); Changed(); };
        handoff.TextChanged += (_, _) => Changed();
        AddView(list, wait.View);
        loop.ItemsSource = new[] { "播完循环再收尾", "立即进入收尾" };
        System.Windows.Automation.AutomationProperties.SetName(loop, "窗口就绪时");
        System.Windows.Automation.AutomationProperties.SetName(customLoop, "自定义窗口就绪时");
        loop.SelectionChanged += (_, _) => Changed();
        var loopRight = new StackPanel { Orientation = Orientation.Horizontal };
        loopDefault.VerticalAlignment = VerticalAlignment.Center; loopDefault.Margin = new(0, 0, 10, 0); loopRight.Children.Add(loopDefault);
        loop.Margin = new(0, 0, 10, 0); loopRight.Children.Add(loop); loopRight.Children.Add(customLoop);
        AddRow(list, "窗口就绪时", loopRight);
        customLoop.Checked += (_, _) => { ShowLoop(); Changed(); }; customLoop.Unchecked += (_, _) => { ShowLoop(); Changed(); };
        return page;
    }

    private FrameworkElement BuildDisplayPage()
    {
        var page = new StackPanel();
        var list = Group(page);
        AddView(list, coverage.View);
        fitMode.ItemsSource = new[] { "使用动画默认设置", "自动适配（推荐）", "铺满（可能裁边）", "完整显示（模糊补边）" };
        System.Windows.Automation.AutomationProperties.SetName(fitMode, "贴到窗口时的显示方式");
        fitMode.SelectionChanged += (_, _) => Changed();
        var fitRow = AddRow(list, "贴到窗口时", fitMode);
        fitRow.ToolTip = "窗口比例和视频接近时铺满；差得多时完整显示整段视频，空边用模糊画面补齐。";
        page.Children.Add(Hint("开场尺寸按屏幕可见区域缩放；收尾仍与目标窗口对齐。"));
        return page;
    }

    private FrameworkElement BuildPresetsPage()
    {
        var page = new StackPanel();
        var list = Group(page);
        var saved = new StackPanel { Orientation = Orientation.Horizontal };
        saved.Children.Add(presets);
        var apply = Button("应用", ApplyPreset, "TextButton"); apply.Margin = new(8, 0, 0, 0); saved.Children.Add(apply);
        saved.Children.Add(Button("删除", DeletePreset, "DangerTextButton"));
        AddRow(list, "已存方案", saved);
        var add = new StackPanel { Orientation = Orientation.Horizontal };
        add.Children.Add(presetName);
        var addButton = Button("存为方案", AddPreset); addButton.Margin = new(8, 0, 0, 0); add.Children.Add(addButton);
        AddRow(list, "新方案", add);
        var reset = Button("恢复本包默认参数", () => Guard(() =>
        {
            draft.MasterVolume = volume.Value; draft.Muted = muted.IsChecked == true; if (this.pack is not null) draft.ResetPack(this.pack.Id);
            LoadControls(); Changed(); status.Text = "已恢复本包默认参数，已存方案仍保留。";
        }));
        reset.HorizontalAlignment = HorizontalAlignment.Left; page.Children.Add(reset);
        page.Children.Add(Hint("方案保存这个动画的过渡、等待、尺寸和显示方式；恢复默认不会删除已存方案。"));
        return page;
    }

    /// <summary>A white grouped list; rows are separated by hairlines.</summary>
    private static StackPanel Group(Panel page)
    {
        var rows = new StackPanel();
        var card = new Border { Child = rows }; card.SetResourceReference(StyleProperty, "Card");
        page.Children.Add(card);
        return rows;
    }

    private static FrameworkElement AddRow(StackPanel list, object title, UIElement? right)
    {
        var row = new DockPanel { MinHeight = 44 };
        if (right is not null) { DockPanel.SetDock(right, Dock.Right); if (right is FrameworkElement f) f.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(right); }
        var label = title as FrameworkElement ?? Text((string)title);
        label.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(label);
        return AddView(list, row);
    }

    /// <summary>Adds a row; rows after the first carry their own divider so hiding a row hides its line too.</summary>
    private static FrameworkElement AddView(StackPanel list, FrameworkElement view)
    {
        if (list.Children.Count == 0) { list.Children.Add(view); return view; }
        var line = new Border { Height = 1 }; line.SetResourceReference(Border.BackgroundProperty, "Divider");
        var block = new StackPanel(); block.Children.Add(line); block.Children.Add(view);
        list.Children.Add(block);
        return block;
    }

    internal void ShowPage(string key)
    {
        if (overviewHero is not null) overviewHero.Visibility = key == "overview" ? Visibility.Collapsed : Visibility.Visible;
        if (key == "overview") RefreshOverview();
        if (key == "targets") _ = InstalledAppsProvider().ContinueWith(_ => BuildTargets(), TaskScheduler.FromCurrentSynchronizationContext());
        foreach (var (name, page) in pages) page.Visibility = name == key ? Visibility.Visible : Visibility.Collapsed;
        if (nav.TryGetValue(key, out var item) && item.IsChecked != true) item.IsChecked = true;
    }

    private void Bind(System.Windows.Input.Key key, Action action)
    {
        var command = new System.Windows.Input.RoutedCommand();
        CommandBindings.Add(new(command, (_, _) => action()));
        InputBindings.Add(new System.Windows.Input.KeyBinding(command, key, System.Windows.Input.ModifierKeys.Control));
    }

    // ---------- state ----------

    public void ReportPreview(EndReason reason)
    {
        status.Text = reason.Kind == EndKind.Failed
            ? "预览失败，请检查动画包文件或重新导入。设置仍可编辑。"
            : reason.Kind == EndKind.WindowTimeout ? "已达到等待上限并结束预览，可继续调整。" : "预览已结束，可继续调整或保存。";
    }

    private void Changed()
    {
        if (loading) return;
        dirty = true; justSaved = false; SetPill(); UpdateStats(); RefreshOverview();
        status.Text = "调整后可直接预览；保存后用于下次播放。";
    }

    private void SetPill()
    {
        var (text, color) = dirty ? ("● 有未保存的修改", "Accent") : justSaved ? ("✓ 设置已保存", "Success") : ("当前设置", "TextSecondary");
        savedLabel.Text = text;
        savedLabel.SetResourceReference(TextBlock.ForegroundProperty, color);
    }

    private ExperienceSettings ReadDraft()
    {
        var next = draft.Copy();
        next.MasterVolume = volume.Value; next.Muted = muted.IsChecked == true;
        if (pack is not null)
        {
            double? at = null;
            if (customHandoff.IsChecked == true)
            {
                if (!double.TryParse(handoff.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value)) throw new ExperienceException("请填写有效的淡出起点秒数");
                at = value;
            }
            if (!next.Packs.TryGetValue(pack.Id, out var p)) next.Packs[pack.Id] = p = new();
            p.Overrides = new() { FadeDuration = fade.Value, HandoffAt = at, MaxWaitSeconds = wait.Value,
                LaunchCoverage = coverage.Value, LoopExit = customLoop.IsChecked == true ? (loop.SelectedIndex == 1 ? LoopExit.Immediate : LoopExit.CycleEnd) : null,
                VideoFit = fitMode.SelectedIndex switch { 1 => VideoFitMode.Auto, 2 => VideoFitMode.Fill, 3 => VideoFitMode.Fit, _ => null } };
        }
        next.Playback.Frequency = firstOfDay.IsChecked == true ? PlayFrequency.FirstOfDay : PlayFrequency.EveryLaunch;
        next.Playback.DayStartHour = Math.Max(0, dayStart.SelectedIndex);
        next.Playback.QuietWhenFullscreen = quiet.IsChecked == true;
        next.Library.Rotation = rotation.SelectedIndex switch { 1 => PackRotation.ShuffleAll, 2 => PackRotation.ShuffleFavorites, _ => PackRotation.Fixed };
        next.Validate(); return next;
    }

    private void LoadControls()
    {
        loading = true;
        var p = (pack is null ? null : draft.Packs.GetValueOrDefault(pack.Id)) ?? new PackPreferences();
        volume.Value = draft.MasterVolume; volumeValue.Text = $"{draft.MasterVolume:P0}"; muted.IsChecked = draft.Muted; volume.IsEnabled = !draft.Muted;
        fade.Load(p.Overrides.FadeDuration); wait.Load(p.Overrides.MaxWaitSeconds); coverage.Load(p.Overrides.LaunchCoverage);
        customHandoff.IsChecked = p.Overrides.HandoffAt is not null;
        handoff.Text = (p.Overrides.HandoffAt ?? pack?.Manifest.HandoffAt ?? 0).ToString(CultureInfo.CurrentCulture);
        handoffDefault.Text = pack?.Manifest.HandoffAt is { } h ? $"默认 {h:0.##} 秒" : "默认 片尾自动";
        ShowHandoff();
        customLoop.IsChecked = p.Overrides.LoopExit is not null;
        loop.SelectedIndex = (p.Overrides.LoopExit ?? (pack?.Manifest.EffectiveLoopExit ?? LoopExit.CycleEnd)) == LoopExit.Immediate ? 1 : 0;
        loopDefault.Text = "默认 " + ((pack?.Manifest.EffectiveLoopExit ?? LoopExit.CycleEnd) == LoopExit.Immediate ? "立即收尾" : "播完循环");
        ShowLoop();
        fitMode.SelectedIndex = p.Overrides.VideoFit switch { VideoFitMode.Auto => 1, VideoFitMode.Fill => 2, VideoFitMode.Fit => 3, _ => 0 };
        presets.ItemsSource = p.Presets; presets.SelectedIndex = -1;
        (draft.Playback.Frequency == PlayFrequency.FirstOfDay ? firstOfDay : everyLaunch).IsChecked = true;
        ShowDayRows();
        dayStart.SelectedIndex = draft.Playback.DayStartHour;
        quiet.IsChecked = draft.Playback.QuietWhenFullscreen;
        rotation.SelectedIndex = draft.Library.Rotation switch { PackRotation.ShuffleAll => 1, PackRotation.ShuffleFavorites => 2, _ => 0 };
        loading = false;
        UpdateToday(); UpdateStats();
    }

    private void ShowDayRows()
    {
        var visible = firstOfDay.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        foreach (var row in dayRows) if (row is not null) row.Visibility = visible;
    }

    private void ShowLoop()
    {
        var custom = customLoop.IsChecked == true;
        loop.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
        loopDefault.Visibility = custom ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ShowHandoff()
    {
        var custom = customHandoff.IsChecked == true;
        handoff.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
        handoffDefault.Visibility = custom ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>The three value tiles show what will actually apply (override or the animation's default).</summary>
    private void UpdateStats()
    {
        statFade.Text = $"{fade.Value ?? (pack?.Manifest.EffectiveFadeDuration ?? .3):0.0} 秒";
        statWait.Text = $"{wait.Value ?? (pack?.Manifest.EffectiveMaxWait ?? 8):0} 秒";
        var exit = customLoop.IsChecked == true ? (loop.SelectedIndex == 1 ? LoopExit.Immediate : LoopExit.CycleEnd) : (pack?.Manifest.EffectiveLoopExit ?? LoopExit.CycleEnd);
        statLoop.Text = exit == LoopExit.Immediate ? "立即收尾" : "播完循环";
    }

    private bool TrySave()
    {
        try
        {
            var next = ReadDraft(); save(next); draft = next.Copy(); dirty = false; justSaved = true; SetPill(); RefreshOverview();
            status.Text = "已保存，下次播放使用这些设置。"; return true;
        }
        catch (Exception e) when (e is ExperienceException or System.IO.IOException or UnauthorizedAccessException) { status.Text = $"未保存：{e.Message}"; return false; }
    }

    private void TryPreview() { if (pack is null) { status.Text = "请先导入可用动画包，再进行预览。"; return; } PreviewPack(pack); }
    private void PreviewPack(InstalledPack target) => Guard(() => { preview(ReadDraft(), target); status.Text = $"正在预览「{target.Manifest.Name}」；未保存的设置不会用于自动播放。"; });
    private void AddPreset() => Guard(() => { if (pack is null) return; var next = ReadDraft(); next.AddPreset(pack.Id, presetName.Text); draft = next; LoadControls(); Changed(); presetName.Text = ""; status.Text = "方案已加入草稿，点击保存设置后保留。"; });
    private void ApplyPreset() => Guard(() => { if (pack is null || presets.SelectedItem is not ExperiencePreset p) return; var next = ReadDraft(); next.Packs[pack.Id].Overrides = p.Overrides.Copy(); draft = next; LoadControls(); Changed(); status.Text = $"已应用「{p.Name}」，可先预览再保存。"; });
    private void DeletePreset() => Guard(() => { if (pack is null || presets.SelectedItem is not ExperiencePreset p) return; draft = ReadDraft(); draft.Packs[pack.Id].Presets.RemoveAll(v => v.Id == p.Id); LoadControls(); Changed(); status.Text = "方案已从草稿移除，保存后生效。"; });
    private void Guard(Action action) { try { action(); } catch (Exception e) when (e is ExperienceException or System.IO.IOException or UnauthorizedAccessException) { status.Text = e.Message; } }

    /// <summary>Refreshes the library after an immediate action. The draft, including unsaved edits, is kept.</summary>
    public void UpdateLibrary(LibraryView view)
    {
        try { if (!loading) draft = ReadDraft(); } catch (ExperienceException) { }
        library = view;
        var same = view.Packs.FirstOrDefault(p => p.Id == pack?.Id);
        pack = same ?? view.Packs.FirstOrDefault(p => p.Id == view.ActiveId) ?? view.Packs.FirstOrDefault();
        var wasDirty = dirty;
        ShowPack(); LoadControls(); BuildCards(); BuildTargets();
        dirty = wasDirty; SetPill(); RefreshOverview();
    }

    private void SwitchTo(InstalledPack target) => Guard(() =>
    {
        if (target.Id == pack?.Id) return;
        draft = ReadDraft(); pack = target;
        var wasDirty = dirty; ShowPack(); LoadControls(); BuildCards(); dirty = wasDirty; SetPill(); RefreshOverview();
        status.Text = $"正在调节「{target.Manifest.Name}」，其他动画的修改仍在草稿中。";
    });

    /// <summary>Hero: the animation being edited.</summary>
    private void ShowPack()
    {
        if (pack is null) { heroName.Text = "还没有可用动画"; heroMeta.Text = "请先导入动画包"; heroCover.Child = null; return; }
        heroName.Text = pack.Manifest.Name;
        ShowHeroMeta(pack);
        Cover(heroCover, pack, 30);
        fade.Fallback = (pack?.Manifest.EffectiveFadeDuration ?? .3); wait.Fallback = (pack?.Manifest.EffectiveMaxWait ?? 8);
    }

    /// <summary>Same subtitle rule as macOS: "轮换中" while rotating, else "当前动画 / 正在调节 · N 秒" (all segments added up).</summary>
    private void ShowHeroMeta(InstalledPack shown)
    {
        var context = library is null || shown.Id == library.ActiveId ? "当前动画" : "正在调节";
        if (rotation.SelectedIndex > 0) { heroMeta.Text = "轮换中"; return; }
        double total = 0;
        foreach (var file in shown.Manifest.Segments.Values)
        {
            var path = shown.PathFor(file);
            var key = path + "|" + System.IO.File.GetLastWriteTimeUtc(path).Ticks;
            if (!Durations.TryGetValue(key, out var seconds)) Durations[key] = seconds = MediaDuration.Read(path);
            if (seconds is not { } s) { heroMeta.Text = context; return; }
            total += s;
        }
        heroMeta.Text = $"{context} · {Math.Round(total, MidpointRounding.ToEven):0} 秒"; // same rounding as macOS (%.0f)
    }

    /// <summary>Cover, first frame, or a soft placeholder with the flower mark.</summary>
    private void Cover(Border target, InstalledPack item, double markSize)
    {
        target.SetResourceReference(Border.BackgroundProperty, "AccentSoft");
        target.Child = new Image { Source = FlowerIcon.Render(96, Theme.Token("AccentFill", Theme.AppsDark)), Width = markSize, Height = markSize, Opacity = 0.55 };
        target.SizeChanged -= ClipRounded; target.SizeChanged += ClipRounded;
        if (library is { CacheRoot.Length: > 0 } view) _ = PackThumbnails.Fill(target, item, view.CacheRoot);
    }

    private static void ClipRounded(object sender, SizeChangedEventArgs e)
    {
        if (sender is Border b) b.Clip = new RectangleGeometry(new Rect(e.NewSize), b.CornerRadius.TopLeft, b.CornerRadius.TopLeft);
    }

    private void ToggleFavorite(string id) => Guard(() =>
    {
        draft = ReadDraft();
        if (!draft.Library.Favorites.Remove(id)) draft.Library.Favorites.Add(id);
        draft.Validate(); BuildCards(); Changed();
        status.Text = draft.Library.Favorites.Contains(id) ? "已加入收藏，保存后生效。" : "已取消收藏，保存后生效。";
    });

    private void BuildCards()
    {
        cards.Children.Clear();
        problemsPanel.Children.Clear();
        var view = library ?? new LibraryView(pack is null ? [] : [pack], new Dictionary<string, string>(), pack?.Id, "", new(), "");
        foreach (var item in view.Packs)
        {
            var selected = item.Id == pack?.Id;
            var favorite = draft.Library.Favorites.Contains(item.Id);
            var isCurrent = item.Id == view.ActiveId;
            var card = new Border { CornerRadius = new(12), Padding = new(10), Margin = new(6), Cursor = System.Windows.Input.Cursors.Hand,
                                    BorderThickness = new(selected ? 1.5 : 1) };
            card.SetResourceReference(Border.BackgroundProperty, selected ? "AccentSoft" : "Surface");
            card.SetResourceReference(Border.BorderBrushProperty, selected ? "Accent" : "Border");
            System.Windows.Automation.AutomationProperties.SetName(card, "动画 " + item.Id);
            var layout = new StackPanel();
            var coverBox = new Grid { Margin = new(0, 0, 0, 8) };
            var cover = new Border { CornerRadius = new(8), ClipToBounds = true };
            cover.SizeChanged += (_, e) => { if (double.IsNaN(cover.Height) || Math.Abs(cover.Height - e.NewSize.Width * 9 / 16) > 1) cover.Height = e.NewSize.Width * 9 / 16; };
            Cover(cover, item, 26);
            coverBox.Children.Add(cover);
            var star = new Button { Content = favorite ? "★" : "☆", FontSize = 15, Height = 26, Width = 26, Padding = new(0),
                                    HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new(0, 6, 6, 0),
                                    ToolTip = favorite ? "取消收藏" : "收藏" };
            star.SetResourceReference(StyleProperty, "PillButton");
            System.Windows.Automation.AutomationProperties.SetName(star, (favorite ? "取消收藏 " : "收藏 ") + item.Id);
            star.Click += (_, e) => { e.Handled = true; ToggleFavorite(item.Id); };
            coverBox.Children.Add(star);
            layout.Children.Add(coverBox);
            var titleRow = new DockPanel();
            if (isCurrent)
            {
                var tag = new Border { CornerRadius = new(4), Padding = new(6, 1, 6, 1), Margin = new(6, 0, 0, 0), Child = Text("当前", 11), VerticalAlignment = VerticalAlignment.Center };
                tag.SetResourceReference(Border.BackgroundProperty, "AccentFill"); ((TextBlock)tag.Child).SetResourceReference(TextBlock.ForegroundProperty, "OnAccent");
                DockPanel.SetDock(tag, Dock.Right); titleRow.Children.Add(tag);
            }
            var name = Text(item.Manifest.Name); name.FontWeight = FontWeights.SemiBold; name.TextTrimming = TextTrimming.CharacterEllipsis; name.TextWrapping = TextWrapping.NoWrap;
            titleRow.Children.Add(name);
            layout.Children.Add(titleRow);
            if (actions is not null)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new(-6, 4, 0, 0) };
                var current = Small("设为当前", () => actions.SetActive(item.Id), "设为当前 " + item.Id); current.IsEnabled = !isCurrent; row.Children.Add(current);
                var remove = Small("移除…", () => ConfirmRemove(item), "移除 " + item.Id, "DangerTextButton");
                if (item.Id == view.BundledId) { remove.IsEnabled = false; remove.ToolTip = "随程序附带的示例动画不能移除"; ToolTipService.SetShowOnDisabled(remove, true); }
                row.Children.Add(remove);
                layout.Children.Add(row);
            }
            card.Child = layout;
            card.MouseLeftButtonUp += (_, _) => SwitchTo(item);
            cards.Children.Add(card);
        }
        if (actions is not null)
        {
            var import = new Button { Content = "＋  导入动画包", Margin = new(6), MinHeight = 120 };
            import.SetResourceReference(StyleProperty, "ImportTile");
            System.Windows.Automation.AutomationProperties.SetName(import, "导入动画包");
            import.Click += (_, _) => actions.Import();
            cards.Children.Add(import);
            var fromVideo = new Button { Margin = new(6), MinHeight = 120 };
            var tileText = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            tileText.Children.Add(new TextBlock { Text = "＋  从视频创建", HorizontalAlignment = HorizontalAlignment.Center });
            var tileHint = new TextBlock { Text = "选一个 mp4 / mov", FontSize = 12, Margin = new(0, 4, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
            tileHint.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
            tileText.Children.Add(tileHint);
            fromVideo.Content = tileText;
            fromVideo.SetResourceReference(StyleProperty, "ImportTile");
            System.Windows.Automation.AutomationProperties.SetName(fromVideo, "从视频创建动画");
            fromVideo.Click += (_, _) => actions.CreateFromVideo();
            cards.Children.Add(fromVideo);
        }
        foreach (var (folder, reason) in view.Problems)
        {
            var problem = Text($"无法使用「{folder}」：{reason}", 12); problem.SetResourceReference(TextBlock.ForegroundProperty, "Danger");
            problem.Margin = new(0, 0, 0, 6); problemsPanel.Children.Add(problem);
        }
    }

    private void ConfirmRemove(InstalledPack item)
    {
        if (actions is null) return;
        var answer = MessageBox.Show(this, $"移除「{item.Manifest.Name}」？\n动画包会移到回收站，可以从回收站还原。你的参数、方案和收藏会保留。",
            "移除动画", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer == MessageBoxResult.OK) actions.Remove(item);
    }

    private void UpdateToday()
    {
        if (library is null) { today.Text = ""; return; }
        var hour = Math.Max(0, dayStart.SelectedIndex);
        var latest = library.State.Targets.Values.Select(t => t.LastAutoPlayAt).Where(t => t is not null).DefaultIfEmpty(null).Max();
        if (latest is not { } last) { today.Text = "今天尚未自动播放"; return; }
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        static double Offset(double t) => TimeZoneInfo.Local.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000))).TotalSeconds;
        var played = ScheduleDecision.Decide(PlayFrequency.FirstOfDay, hour, new() { LastAutoPlayAt = last }, now, Offset(now), Offset(last)) == ScheduleOutcome.PlayedToday;
        var at = DateTimeOffset.FromUnixTimeMilliseconds((long)(last * 1000)).ToLocalTime();
        today.Text = played ? $"今天已于 {at:HH:mm} 播放" : "今天尚未自动播放";
    }

    private void ConfirmClose(object? sender, CancelEventArgs e)
    {
        if (!dirty) return;
        var result = MessageBox.Show(this, "保存启动体验的修改？\n尚未保存的参数和方案会在关闭后丢失。", "Sakura", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        e.Cancel = result == MessageBoxResult.Cancel || (result == MessageBoxResult.Yes && !TrySave());
    }

    public bool RequestClose() { if (!closed) Close(); return closed; }

    // ---------- small builders ----------

    private static TextBlock Text(string text, double size = 13)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        return t;
    }
    private static TextBlock Secondary(string text, double size = 12)
    {
        var t = Text(text, size); t.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary"); return t;
    }
    private static TextBlock Hint(string text) { var t = Secondary(text); t.Margin = new(4, 0, 0, 12); return t; }
    private static TextBlock Stat()
    {
        var t = Text("", 16); t.FontWeight = FontWeights.SemiBold;
        System.Windows.Documents.Typography.SetNumeralAlignment(t, FontNumeralAlignment.Tabular);
        return t;
    }
    private static TextBlock Value(string text)
    {
        var t = Secondary(text, 12); t.Width = 48; t.TextAlignment = TextAlignment.Right; t.VerticalAlignment = VerticalAlignment.Center;
        System.Windows.Documents.Typography.SetNumeralAlignment(t, FontNumeralAlignment.Tabular);
        return t;
    }
    private static Button Button(string title, Action action, string? style = null)
    {
        var b = new Button { Content = title };
        if (style is not null) b.SetResourceReference(StyleProperty, style);
        b.Click += (_, _) => action();
        return b;
    }
    private static Button Small(string title, Action action, string automationName, string style = "TextButton")
    {
        var b = new Button { Content = title };
        b.SetResourceReference(StyleProperty, style);
        System.Windows.Automation.AutomationProperties.SetName(b, automationName);
        b.Click += (_, e) => { e.Handled = true; action(); };
        return b;
    }

    /// <summary>
    /// A row for a value the animation defines: title, "默认 …" on the right while inherited, and a "自定义" switch that
    /// reveals the slider. The switch and the slider row are children of <see cref="View"/> (UiChecks relies on that).
    /// </summary>
    private sealed class OverrideSlider
    {
        public StackPanel View { get; } = new() { MinHeight = 44 };
        private readonly CheckBox custom = new() { Content = "自定义" };
        private readonly Slider slider;
        private readonly DockPanel row;
        private readonly TextBlock defaultText;
        private readonly bool percent;
        public double Fallback { get; set; }
        public double? Value => custom.IsChecked == true ? slider.Value : null;
        public OverrideSlider(string title, double min, double max, double step, double fallback, Action changed, bool percent = false)
        {
            Fallback = fallback; this.percent = percent;
            slider = new() { Minimum = min, Maximum = max, TickFrequency = step, IsSnapToTickEnabled = true };
            System.Windows.Automation.AutomationProperties.SetName(slider, title);
            var header = new DockPanel { MinHeight = 44 };
            var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            defaultText = Secondary(""); defaultText.VerticalAlignment = VerticalAlignment.Center; defaultText.Margin = new(0, 0, 12, 0);
            right.Children.Add(defaultText); right.Children.Add(custom);
            DockPanel.SetDock(right, Dock.Right); header.Children.Add(right);
            var label = Text(title); label.VerticalAlignment = VerticalAlignment.Center; header.Children.Add(label);
            View.Children.Add(header);
            var value = ExperienceWindow.Value("");
            row = new DockPanel { Margin = new(0, 0, 0, 12) }; DockPanel.SetDock(value, Dock.Right); row.Children.Add(value); row.Children.Add(slider);
            View.Children.Add(row);
            slider.ValueChanged += (_, _) => { value.Text = Format(slider.Value); changed(); };
            void Toggle() { slider.IsEnabled = custom.IsChecked == true; Update(); changed(); }
            custom.Checked += (_, _) => Toggle(); custom.Unchecked += (_, _) => Toggle();
        }
        private string Format(double v) => percent ? $"{v:P0}" : $"{v:0.0} 秒";
        private void Update()
        {
            var on = custom.IsChecked == true;
            defaultText.Text = $"默认 {Format(Fallback)}";
            defaultText.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
            row.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        }
        public void Load(double? value) { slider.Value = value ?? Fallback; custom.IsChecked = value is not null; slider.IsEnabled = value is not null; Update(); }
    }
}
