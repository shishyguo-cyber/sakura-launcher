using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using GardenBoot.Core;

namespace GardenBoot.App;

internal sealed partial class ExperienceWindow
{
    private readonly IOverviewRuntime? runtime;
    private bool welcomeDismissed, refreshingOverview;
    private string overviewAction = "none";
    private readonly ComboBox overviewTargets = new() { MinWidth = 150, MaxWidth = 230, SelectedValuePath = "Id" };
    private readonly TextBlock overviewTitle = Text("", 19), overviewDetail = Text("", 13);
    private readonly TextBlock overviewDraft = Secondary("你有未保存的修改。上方状态仍依据已保存设置；草稿可以先预览。");
    private readonly StackPanel overviewGuide = new();
    private readonly List<Button> overviewPreviews = [];
    private Button? overviewActionButton, overviewReopenGuide;
    private FrameworkElement? overviewHero;
    private DispatcherTimer? overviewTimer;
    private readonly TextBlock updateVersion = Secondary(""), updateResult = Secondary("");
    private readonly CheckBox automaticUpdates = new() { Content = "自动检查更新" };
    private Button? checkUpdatesButton, downloadUpdateButton;

    private FrameworkElement BuildOverviewPage()
    {
        var page = new StackPanel();
        var heading = new DockPanel { Margin = new(0, 0, 0, 18) };
        overviewReopenGuide = Small("查看使用引导", () => SetWelcome(false), "查看使用引导");
        overviewReopenGuide.HorizontalAlignment = HorizontalAlignment.Right;
        DockPanel.SetDock(overviewReopenGuide, Dock.Right); heading.Children.Add(overviewReopenGuide);
        var titles = new StackPanel();
        var title = Text("你的启动体验", 24); title.FontWeight = FontWeights.SemiBold; titles.Children.Add(title);
        var subtitle = Secondary("看看当前状态，再按自己的习惯调整。", 13); subtitle.Margin = new(0, 6, 0, 0); titles.Children.Add(subtitle);
        heading.Children.Add(titles); page.Children.Add(heading);

        var summary = new StackPanel();
        var targetLine = new DockPanel { Margin = new(0, 0, 0, 12) };
        DockPanel.SetDock(overviewTargets, Dock.Right); targetLine.Children.Add(overviewTargets);
        targetLine.Children.Add(Secondary("自动播放状态")); summary.Children.Add(targetLine);
        AutomationProperties.SetName(overviewTargets, "查看状态的应用");
        overviewTargets.SelectionChanged += (_, _) => { if (!refreshingOverview) RefreshOverview(); };
        overviewTitle.FontWeight = FontWeights.SemiBold;
        overviewTitle.SetResourceReference(TextBlock.ForegroundProperty, "HeroText");
        AutomationProperties.SetAutomationId(overviewTitle, "overview-status-title");
        summary.Children.Add(overviewTitle);
        overviewDetail.SetResourceReference(TextBlock.ForegroundProperty, "HeroSecondary");
        overviewDetail.Margin = new(0, 8, 0, 12); summary.Children.Add(overviewDetail);
        var commands = new StackPanel { Orientation = Orientation.Horizontal };
        overviewActionButton = Small("", PerformStatusAction, "播放状态操作", "SmallButton");
        overviewActionButton.Margin = new(0, 0, 12, 0); commands.Children.Add(overviewActionButton);
        commands.Children.Add(OverviewPreview("预览当前动画")); summary.Children.Add(commands);
        var surface = new Border { CornerRadius = new(14), Padding = new(18), Child = summary, Margin = new(0, 0, 0, 18) };
        surface.SetResourceReference(Border.BackgroundProperty, "Hero"); page.Children.Add(surface);

        page.Children.Add(BuildUpdateOverview());

        var guideHeading = new DockPanel();
        var dismiss = Small("我已了解", () => SetWelcome(true), "关闭使用引导");
        DockPanel.SetDock(dismiss, Dock.Right); guideHeading.Children.Add(dismiss);
        var guideTitle = Text("三步开始", 15); guideTitle.FontWeight = FontWeights.SemiBold; guideHeading.Children.Add(guideTitle);
        overviewGuide.Children.Add(guideHeading);
        GuideStep("1", "选一个常用应用", "添加或启用应用，保存后开始监听。", "选择应用", () => ShowPage("targets"));
        GuideStep("2", "挑一段动画", "设为当前动画，或在应用页单独指定。", "选择动画", () => ShowPage("animation"));
        GuideStep("3", "预览并保存", "预览使用草稿；左下角保存后用于自动播放。", "预览", TryPreview);
        var location = Secondary("关闭设置后仍在通知区域运行。从花朵图标可以重新打开设置或退出 Sakura。");
        location.Margin = new(0, 12, 0, 0); overviewGuide.Children.Add(location);
        var guideSurface = new Border { CornerRadius = new(12), Padding = new(16), Child = overviewGuide, Margin = new(0, 0, 0, 12) };
        guideSurface.SetResourceReference(Border.BackgroundProperty, "Surface");
        // Collapse the whole surface, so a dismissed guide leaves no empty card.
        overviewGuide.Tag = guideSurface;
        page.Children.Add(guideSurface); page.Children.Add(overviewDraft);
        Loaded += (_, _) =>
        {
            RefreshOverview();
            if (runtime is not null)
            {
                overviewTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1) };
                overviewTimer.Tick += (_, _) => { if (IsVisible) RefreshOverview(); };
                overviewTimer.Start();
            }
        };
        Closed += (_, _) => { overviewTimer?.Stop(); overviewTimer = null; };
        return page;
    }

    private FrameworkElement BuildUpdateOverview()
    {
        var body = new StackPanel();
        var heading = new DockPanel();
        checkUpdatesButton = Small("检查更新", () => Guard(() => { runtime?.CheckForUpdatesFromSettings(); RefreshOverview(); }), "检查更新", "SmallButton");
        DockPanel.SetDock(checkUpdatesButton, Dock.Right); heading.Children.Add(checkUpdatesButton);
        var title = new StackPanel();
        var label = Text("版本与更新", 15); label.FontWeight = FontWeights.SemiBold; title.Children.Add(label);
        updateVersion.Margin = new(0, 4, 0, 0); title.Children.Add(updateVersion);
        heading.Children.Add(title); body.Children.Add(heading);
        var result = new DockPanel { Margin = new(0, 12, 0, 12) };
        downloadUpdateButton = Small("更新", () => runtime?.OpenUpdateDownload(), "更新", "PrimaryButton");
        DockPanel.SetDock(downloadUpdateButton, Dock.Right); result.Children.Add(downloadUpdateButton);
        var fallback = Small("在 GitHub 查看", () => runtime?.OpenUpdateFallback(), "在 GitHub 查看", "SmallButton");
        DockPanel.SetDock(fallback, Dock.Right); result.Children.Add(fallback);
        updateResult.VerticalAlignment = VerticalAlignment.Center;
        updateResult.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetAutomationId(updateResult, "overview-update-result");
        result.Children.Add(updateResult); body.Children.Add(result);
        var requirement = Secondary(UpdateRules.GitHubRequirement);
        requirement.Margin = new(0, 0, 0, 12);
        AutomationProperties.SetAutomationId(requirement, "overview-update-requirement");
        body.Children.Add(requirement);
        var line = new Border { Height = 1, Margin = new(0, 0, 0, 12) };
        line.SetResourceReference(Border.BackgroundProperty, "Divider"); body.Children.Add(line);
        AutomationProperties.SetName(automaticUpdates, "自动检查更新");
        void ChangedUpdate(object sender, RoutedEventArgs e)
        {
            if (refreshingOverview || runtime is null) return;
            Guard(() => { runtime.SetAutomaticUpdates(automaticUpdates.IsChecked == true); RefreshOverview(); });
        }
        automaticUpdates.Checked += ChangedUpdate; automaticUpdates.Unchecked += ChangedUpdate;
        body.Children.Add(automaticUpdates);
        var hint = Secondary("每周检查一次，发现新版本时提醒你。"); hint.Margin = new(0, 4, 0, 0); body.Children.Add(hint);
        var surface = new Border { CornerRadius = new(12), Padding = new(16), BorderThickness = new(1), Child = body, Margin = new(0, 0, 0, 18) };
        surface.SetResourceReference(Border.BackgroundProperty, "Surface"); surface.SetResourceReference(Border.BorderBrushProperty, "Border");
        AutomationProperties.SetAutomationId(surface, "overview-updates");
        return surface;
    }

    private void RefreshUpdates()
    {
        if (checkUpdatesButton is null || downloadUpdateButton is null) return;
        var state = runtime?.UpdateOverview() ?? new UpdateOverview(ApplicationController.ReleaseVersion, false,
            Message: "正式运行 Sakura 后，可在这里检查更新。", Connected: false);
        updateVersion.Text = "Sakura " + state.Version;
        updateResult.Text = state.Checking ? "正在检查更新…" : state.Message;
        updateResult.SetResourceReference(TextBlock.ForegroundProperty, state.AvailableVersion is null ? "TextSecondary" : "Success");
        checkUpdatesButton.Content = state.Checking ? "正在检查…" : "检查更新";
        checkUpdatesButton.IsEnabled = state.Connected && !state.Checking && !state.Installing;
        downloadUpdateButton.Content = state.Installing ? "取消下载" : "更新";
        AutomationProperties.SetName(downloadUpdateButton, (string)downloadUpdateButton.Content);
        downloadUpdateButton.Visibility = state.Connected && state.AvailableVersion is not null ? Visibility.Visible : Visibility.Collapsed;
        automaticUpdates.IsEnabled = state.Connected;
        automaticUpdates.IsChecked = state.Automatic;
    }

    private Button OverviewPreview(string title)
    {
        var button = Small(title, TryPreview, "预览当前动画");
        overviewPreviews.Add(button); return button;
    }

    private void GuideStep(string number, string title, string detail, string action, Action run)
    {
        var row = new Grid { Margin = new(0, 16, 0, 0) };
        row.ColumnDefinitions.Add(new() { Width = new(36) }); row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var badge = Text(number, 12); badge.FontWeight = FontWeights.SemiBold; badge.SetResourceReference(TextBlock.ForegroundProperty, "Accent"); row.Children.Add(badge);
        var body = new StackPanel(); var label = Text(title, 13); label.FontWeight = FontWeights.Medium; body.Children.Add(label);
        var hint = Secondary(detail); hint.Margin = new(0, 4, 8, 0); body.Children.Add(hint); Grid.SetColumn(body, 1); row.Children.Add(body);
        var button = Small(action, run, "引导 " + action); Grid.SetColumn(button, 2); row.Children.Add(button);
        if (number == "3") overviewPreviews.Add(button);
        overviewGuide.Children.Add(row);
    }

    private void RefreshOverview()
    {
        if (refreshingOverview || overviewActionButton is null) return;
        refreshingOverview = true;
        try
        {
            var selected = overviewTargets.SelectedValue as string;
            var snapshot = runtime?.Overview(selected) ?? new OverviewSnapshot(
                draft.Targets.Where(t => t.Windows is not null).Select(t => new OverviewTarget(t.Id, t.Name)).ToList(),
                null, PlaybackStatusReason.Resolve(new()), false);
            var before = overviewTargets.Items.Cast<OverviewTarget>().ToList();
            if (!before.SequenceEqual(snapshot.Targets)) overviewTargets.ItemsSource = snapshot.Targets;
            overviewTargets.SelectedValue = snapshot.SelectedId;
            overviewTargets.Visibility = snapshot.Targets.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            overviewTitle.Text = snapshot.Connected ? snapshot.Reason.Title : "界面预览";
            overviewDetail.Text = snapshot.Connected ? snapshot.Reason.Detail : "正式运行 Sakura 后，这里会显示所选应用的自动播放状态。";
            overviewAction = snapshot.Connected ? snapshot.Reason.Action : "none";
            var action = overviewAction switch { "targets" => "查看应用", "animation" => "检查动画", "playback" => "调整播放规则", "unpause" => "取消暂停", "unsnooze" => "结束临时暂停", _ => "" };
            overviewActionButton.Content = action;
            overviewActionButton.Visibility = action.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            if (overviewGuide.Tag is FrameworkElement surface) surface.Visibility = welcomeDismissed ? Visibility.Collapsed : Visibility.Visible;
            if (overviewReopenGuide is not null) overviewReopenGuide.Visibility = welcomeDismissed ? Visibility.Visible : Visibility.Collapsed;
            overviewDraft.Visibility = dirty ? Visibility.Visible : Visibility.Collapsed;
            foreach (var button in overviewPreviews) button.IsEnabled = pack is not null;
            RefreshUpdates();
        }
        finally { refreshingOverview = false; }
    }

    private void SetWelcome(bool value) => Guard(() =>
    {
        runtime?.SetWelcomeDismissed(value); welcomeDismissed = value; RefreshOverview();
    });

    private void PerformStatusAction()
    {
        if (overviewAction is "targets" or "animation" or "playback") ShowPage(overviewAction);
        else Guard(() => { runtime?.PerformOverviewAction(overviewAction); RefreshOverview(); });
    }
}
