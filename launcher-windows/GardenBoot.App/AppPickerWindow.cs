using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace GardenBoot.App;

/// <summary>"添加应用": search the Start menu's apps and add one (launcher-spec/TARGETS.md §4–5).</summary>
internal sealed class AppPickerWindow : Window
{
    private readonly TextBox search = new() { Margin = new(0, 0, 0, 12) };
    private readonly StackPanel rows = new();
    private readonly TextBlock status = new() { FontSize = 12, Margin = new(2, 0, 0, 8) };
    private readonly HashSet<string> added;
    private readonly Action<InstalledApp> onAdd;
    private IReadOnlyList<InstalledApp> apps = [];

    public AppPickerWindow(Func<Task<IReadOnlyList<InstalledApp>>> provider, HashSet<string> alreadyAdded, Action<InstalledApp> add)
    {
        added = alreadyAdded; onAdd = add;
        Title = "添加应用"; Width = 520; Height = 560; MinWidth = 420; MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Segoe UI Variable Text, Microsoft YaHei UI"); FontSize = 13;
        SetResourceReference(BackgroundProperty, "Bg"); SetResourceReference(ForegroundProperty, "Text");
        status.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        System.Windows.Automation.AutomationProperties.SetName(search, "搜索应用");
        search.TextChanged += (_, _) => Fill();
        var root = new DockPanel { Margin = new(20) };
        var header = new StackPanel();
        var title = new TextBlock { Text = "添加应用", FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new(0, 0, 0, 12) };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        header.Children.Add(title); header.Children.Add(search); header.Children.Add(status);
        DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        var card = new Border { Child = new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, Padding = new(6) };
        card.SetResourceReference(StyleProperty, "Card");
        root.Children.Add(card);
        Content = root;
        status.Text = "正在读取已安装的应用…";
        SourceInitialized += (_, _) => Theme.UseDarkTitleBar(this, Theme.AppsDark);
        Loaded += async (_, _) =>
        {
            try { apps = await provider(); status.Text = apps.Count == 0 ? "没有读到可添加的应用。" : $"共 {apps.Count} 个应用"; }
            catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or UnauthorizedAccessException)
            { status.Text = "读取已安装的应用失败：" + e.Message; }
            Fill();
            search.Focus();
        };
    }

    private void Fill()
    {
        rows.Children.Clear();
        var query = search.Text.Trim();
        foreach (var app in apps.Where(a => query.Length == 0 || a.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)).Take(300))
        {
            var row = new DockPanel { Margin = new(6, 4, 6, 4), MinHeight = 40 };
            var isAdded = added.Contains(app.Key);
            var action = new Button { Content = isAdded ? "已添加" : "添加", IsEnabled = !isAdded, MinWidth = 64 };
            action.SetResourceReference(StyleProperty, "SmallButton");
            System.Windows.Automation.AutomationProperties.SetName(action, "添加 " + app.Name);
            action.Click += (_, _) => { onAdd(app); added.Add(app.Key); Fill(); };
            DockPanel.SetDock(action, Dock.Right); row.Children.Add(action);
            var icon = new Border { Width = 32, Height = 32, CornerRadius = new(6), Margin = new(0, 0, 10, 0), ClipToBounds = true,
                                    Child = app.Icon is { } source ? new Image { Source = source } : null };
            icon.SetResourceReference(Border.BackgroundProperty, "AccentSoft");
            DockPanel.SetDock(icon, Dock.Left); row.Children.Add(icon);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var name = new TextBlock { Text = app.Name, TextTrimming = TextTrimming.CharacterEllipsis };
            name.SetResourceReference(TextBlock.ForegroundProperty, "Text");
            var detail = new TextBlock { Text = app.Detail, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
            detail.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
            text.Children.Add(name); text.Children.Add(detail); row.Children.Add(text);
            rows.Children.Add(row);
        }
    }
}
