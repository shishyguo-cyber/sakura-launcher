using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>"从视频创建动画": name + rights confirmation before a video becomes a pack (launcher-spec/PACK-FROM-VIDEO.md).</summary>
internal sealed class VideoPackDialog : Window
{
    private readonly TextBox name = new() { Margin = new(0, 6, 0, 4) };
    private readonly TextBlock nameError = new() { Text = "名称需为 1–40 个字符", FontSize = 12, Visibility = Visibility.Collapsed };
    private readonly CheckBox rights = new() { Content = "这个视频是我自己制作的，或我有权使用它", Margin = new(0, 12, 0, 0) };
    private readonly Button create = new() { Content = "创建", IsDefault = true, MinWidth = 88, Margin = new(8, 0, 0, 0) };

    public string PackName => name.Text.Trim();

    public VideoPackDialog(string fileName)
    {
        Title = "从视频创建动画"; Width = 460; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Segoe UI Variable Text, Microsoft YaHei UI"); FontSize = 13;
        SetResourceReference(BackgroundProperty, "Bg"); SetResourceReference(ForegroundProperty, "Text");
        var root = new StackPanel { Margin = new(24) };
        var title = new TextBlock { Text = "从视频创建动画", FontSize = 18, FontWeight = FontWeights.SemiBold };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        var file = new TextBlock { Text = fileName, FontSize = 12, Margin = new(0, 4, 0, 16), TextTrimming = TextTrimming.CharacterEllipsis };
        file.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        var label = new TextBlock { Text = "名称" }; label.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        name.Text = VideoPackRules.DefaultName(fileName);
        System.Windows.Automation.AutomationProperties.SetName(name, "动画名称");
        nameError.SetResourceReference(TextBlock.ForegroundProperty, "Danger");
        var hint = new TextBlock { Text = "会复制一份视频到动画库，视频结尾前自动淡出；之后可在“声音与过渡”里调整淡出起点。",
                                   FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new(0, 12, 0, 20) };
        hint.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        var cancel = new Button { Content = "取消", IsCancel = true, MinWidth = 72 };
        cancel.SetResourceReference(StyleProperty, "TextButton");
        create.SetResourceReference(StyleProperty, "PrimaryButton");
        create.Click += (_, _) => { if (create.IsEnabled) DialogResult = true; };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(cancel); buttons.Children.Add(create);
        foreach (var child in new UIElement[] { title, file, label, name, nameError, rights, hint, buttons }) root.Children.Add(child);
        Content = root;
        name.TextChanged += (_, _) => Validate();
        rights.Checked += (_, _) => Validate(); rights.Unchecked += (_, _) => Validate();
        Validate();
        SourceInitialized += (_, _) => Theme.UseDarkTitleBar(this, Theme.AppsDark);
        Loaded += (_, _) => { name.Focus(); name.SelectAll(); };
    }

    private void Validate()
    {
        var valid = VideoPackRules.ValidName(name.Text);
        nameError.Visibility = valid ? Visibility.Collapsed : Visibility.Visible;
        create.IsEnabled = valid && rights.IsChecked == true;
    }
}
