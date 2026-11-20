using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using GardenBoot.Core;

namespace GardenBoot.App;

internal sealed class OverlayWindow : Window
{
    // Centre alignment matters: WPF places an element larger than its slot at the top-left unless told otherwise,
    // which used to crop only the right/bottom of the picture.
    private readonly Image video = new() { Stretch = Stretch.UniformToFill, IsHitTestVisible = false,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    // Shown only in fit mode: the same picture filling the frame, blurred and dimmed, so no black bars appear.
    private readonly Image backdrop = new() { Stretch = Stretch.UniformToFill, IsHitTestVisible = false, Visibility = Visibility.Collapsed,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 30, KernelType = System.Windows.Media.Effects.KernelType.Gaussian } };
    private readonly Border dim = new() { Background = new SolidColorBrush(Color.FromArgb(51, 0, 0, 0)), IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    private readonly Grid surface = new() { Background = Brushes.Black, ClipToBounds = true };
    private VideoFitMode? applied;
    public VideoFitMode FitMode { get; set; } = VideoFitMode.Auto;
    public Action<string>? Log { get; set; }
    private readonly TextBlock hint = new()
    {
        Text = "点击或按 Esc 跳过", Foreground = Brushes.White, FontSize = 12,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
        Margin = new Thickness(16, 0, 16, 18), Opacity = 0, IsHitTestVisible = false,
        Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 4, ShadowDepth = 0, Opacity = 0.8 },
    };
    private readonly Action skip;
    private nint handle;
    public OverlayWindow(Action skip)
    {
        this.skip = skip;
        Title = "Sakura";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        Background = Brushes.Black;
        AllowsTransparency = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        surface.Children.Add(backdrop);
        surface.Children.Add(dim);
        surface.Children.Add(video);
        surface.SizeChanged += (_, _) => ApplyFit();
        surface.Children.Add(hint);
        Content = surface;
        // Preview catches left/right/middle clicks before any media child can consume them.
        PreviewMouseDown += (_, e) => { e.Handled = true; skip(); };
        System.Windows.Automation.AutomationProperties.SetName(surface, "跳过启动动画");
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            // Layered with a whole-window alpha: WPF ignores Window.Opacity unless AllowsTransparency is set,
            // which would force slow software composition for video. Starts fully transparent.
            // The hook goes first: it keeps WS_EX_LAYERED through WPF's own style updates (see WindowProc).
            HwndSource.FromHwnd(handle)?.AddHook(WindowProc);
            Native.SetExStyle(handle, Native.GetExStyle(handle) | Native.WsExNoActivate | Native.WsExToolWindow | Native.WsExLayered);
            Native.SetLayeredWindowAttributes(handle, 0, 0, Native.LwaAlpha);
            int rounded = 2; // DWMWCP_ROUND; ignored on older Windows
            Native.DwmSetWindowAttribute(handle, 33, ref rounded, sizeof(int));
        };
        new WindowInteropHelper(this).EnsureHandle();
    }

    private nint WindowProc(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == Native.WmMouseActivate) { handled = true; return 3; } // MA_NOACTIVATE, keep the click
        if (message == Native.WmStyleChanging && wParam == Native.GwlExStyle)
        {
            // WPF drops WS_EX_LAYERED unless AllowsTransparency is set (measured: the bit never stuck).
            // Keep it so the whole-window alpha works while video stays on the hardware-rendered path.
            var change = System.Runtime.InteropServices.Marshal.PtrToStructure<Native.StyleStruct>(lParam);
            change.StyleNew |= (uint)Native.WsExLayered;
            System.Runtime.InteropServices.Marshal.StructureToPtr(change, lParam, false);
            handled = true;
            return 0;
        }
        return 0;
    }

    public double Alpha { get; private set; }

    /// <summary>Whole-window opacity through the layered-window alpha (0 = invisible, clicks pass through to nothing).</summary>
    public void SetAlpha(double alpha)
    {
        Alpha = Math.Clamp(double.IsFinite(alpha) ? alpha : 0, 0, 1);
        if (handle == 0) return;
        // WPF rewrites the extended style when the window is shown, so make sure the layered bit is still there.
        var style = Native.GetExStyle(handle);
        if ((style & Native.WsExLayered) == 0) Native.SetExStyle(handle, style | Native.WsExLayered);
        Native.SetLayeredWindowAttributes(handle, 0, (byte)Math.Round(Alpha * 255), Native.LwaAlpha);
    }

    public void SetImage(ImageSource image)
    {
        video.Source = image; backdrop.Source = image;
        ApplyFit();
    }

    /// <summary>Chooses fill or fit for the current frame size and picture (launcher-spec/VIDEO-FIT.md).</summary>
    private void ApplyFit()
    {
        if (video.Source is not { } source || surface.ActualWidth <= 0 || surface.ActualHeight <= 0) return;
        var (mode, _) = VideoFit.Resolve(FitMode, surface.ActualWidth, surface.ActualHeight, source.Height > 0 ? source.Width / source.Height : 0);
        video.Stretch = mode == VideoFitMode.Fill ? Stretch.UniformToFill : Stretch.Uniform;
        var fit = mode == VideoFitMode.Fit;
        backdrop.Visibility = dim.Visibility = fit ? Visibility.Visible : Visibility.Collapsed;
        if (fit && backdrop.Effect is System.Windows.Media.Effects.BlurEffect blur)
            blur.Radius = Math.Clamp(Math.Min(surface.ActualWidth, surface.ActualHeight) * 0.04, 8, 60);
        if (applied != mode) { applied = mode; Log?.Invoke($"video-fit mode={mode.LogName()} requested={FitMode.LogName()}"); }
    }
    /// <summary>Shows a drawn greeting (the built-in Welcome) instead of video, under the skip hint.</summary>
    public void ShowGreeting(UIElement view) => surface.Children.Insert(surface.Children.IndexOf(hint), view);

    public void SetHint(double opacity, bool hasEscape)
    {
        hint.Text = hasEscape ? "点击或按 Esc 跳过" : "点击跳过（Esc 被其他程序占用）";
        hint.Opacity = opacity;
    }
    public Box FrameAtScale(double scale)
    {
        Native.GetWindowRect(handle, out var rect);
        return TargetMonitor.ToBox(rect, scale);
    }
    /// <summary>Shows the window without it ever being visible: off-screen first, alpha 0, then moved into place.</summary>
    public void ShowHidden(DesktopFrame frame)
    {
        Native.SetWindowPos(handle, Native.HwndTopmost, -32000, -32000, 1, 1, Native.SwpNoActivate | Native.SwpNoOwnerZOrder);
        Show();
        SetAlpha(0);
        SetFrame(frame);
    }

    public void SetFrame(DesktopFrame frame)
    {
        // Native positioning uses physical desktop pixels. Interpolation is done in one selected
        // monitor's DIP space, so mixed-DPI/negative-origin monitors never mix coordinate bases.
        var b = frame.Bounds;
        Native.SetWindowPos(handle, Native.HwndTopmost,
            (int)Math.Round(b.X * frame.Scale), (int)Math.Round(b.Y * frame.Scale),
            Math.Max(1, (int)Math.Round(b.Width * frame.Scale)), Math.Max(1, (int)Math.Round(b.Height * frame.Scale)),
            Native.SwpNoActivate | Native.SwpNoOwnerZOrder);
    }
}
