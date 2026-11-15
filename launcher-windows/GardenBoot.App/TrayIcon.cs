using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;

namespace GardenBoot.App;

internal sealed record TrayEntry(string Title = "", Action? Click = null, bool Enabled = true, bool Checked = false,
                                  IReadOnlyList<TrayEntry>? Children = null, bool Separator = false);

/// <summary>Native shell notification icon and menus. No WinForms or third-party tray dependency.</summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly HwndSource source;
    private readonly uint taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
    private Native.NotifyIconData data;
    private Action? escape;
    private bool hotkeyRegistered, added, disposed;
    public Func<IReadOnlyList<TrayEntry>>? BuildMenu { get; set; }

    public TrayIcon()
    {
        source = new HwndSource(new HwndSourceParameters("GardenBoot.Tray")
        {
            WindowStyle = unchecked((int)0x80000000), ExtendedWindowStyle = (int)Native.WsExToolWindow,
            Width = 0, Height = 0,
        });
        source.AddHook(WindowProc);
        data = new Native.NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<Native.NotifyIconData>(), Window = source.Handle, Id = 1,
            Flags = 1 | 2 | 4, CallbackMessage = CallbackMessage,
            Icon = 0, Tip = "Sakura", Info = "", InfoTitle = "",
        };
        AllowDarkMenus();
        data.Icon = FlowerIcon.Create(Native.GetSystemMetrics(49), Theme.TaskbarDark); // SM_CXSMICON
        Add();
        Theme.Changed += RefreshIcon;
    }

    /// <summary>Re-draws the icon in the taskbar's colour after a light/dark switch.</summary>
    private void RefreshIcon()
    {
        if (disposed) return;
        var old = data.Icon;
        data.Icon = FlowerIcon.Create(Native.GetSystemMetrics(49), Theme.TaskbarDark);
        if (added) Native.Shell_NotifyIcon(1, ref data); // NIM_MODIFY
        if (old != 0) Native.DestroyIcon(old);
    }

    /// <summary>Lets native menus follow the system dark mode (uxtheme ordinals 135/136; silently skipped if absent).</summary>
    private static void AllowDarkMenus()
    {
        try
        {
            var uxtheme = Native.LoadLibrary("uxtheme.dll");
            if (uxtheme == 0) return;
            var setMode = Native.GetProcAddress(uxtheme, 135);
            var flush = Native.GetProcAddress(uxtheme, 136);
            if (setMode != 0) Marshal.GetDelegateForFunctionPointer<SetPreferredAppMode>(setMode)(1); // AllowDark
            if (flush != 0) Marshal.GetDelegateForFunctionPointer<FlushMenuThemes>(flush)();
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException or MarshalDirectiveException) { }
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int SetPreferredAppMode(int mode);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void FlushMenuThemes();

    private void Add()
    {
        added = Native.Shell_NotifyIcon(0, ref data); // NIM_ADD
        if (added) { data.Version = 4; Native.Shell_NotifyIcon(4, ref data); }
    }

    public bool SetEscape(Action? handler)
    {
        if (hotkeyRegistered) Native.UnregisterHotKey(source.Handle, Native.EscapeId);
        escape = handler;
        hotkeyRegistered = handler is not null && Native.RegisterHotKey(source.Handle, Native.EscapeId, 0x4000, 0x1b);
        return hotkeyRegistered;
    }

    private nint WindowProc(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if ((uint)message == taskbarCreated && !disposed) { added = false; Add(); }
        if (message == Native.WmHotkey && wParam.ToInt32() == Native.EscapeId)
        { handled = true; escape?.Invoke(); }
        if ((uint)message == CallbackMessage)
        {
            var notification = (uint)lParam.ToInt64() & 0xffff;
            if (notification is 0x205 or 0x7b or 0x400 or 0x401) // right-up, context, select, keyboard select
                ShowMenu();
            handled = true;
        }
        return 0;
    }

    private void ShowMenu()
    {
        if (BuildMenu is null) return;
        var actions = new Dictionary<uint, Action>();
        uint next = 1;
        nint MakeMenu(IReadOnlyList<TrayEntry> entries)
        {
            var menu = Native.CreatePopupMenu();
            foreach (var entry in entries)
            {
                uint flags = entry.Separator ? 0x800u : (entry.Enabled ? 0u : 3u) | (entry.Checked ? 8u : 0u);
                // Ampersands in pack names are text, not menu mnemonics.
                var title = entry.Title.Replace("&", "&&");
                if (entry.Children is { } children)
                    Native.AppendMenu(menu, flags | 0x10, (nuint)MakeMenu(children), title);
                else
                {
                    var id = next++;
                    if (entry.Click is { } action) actions[id] = action;
                    Native.AppendMenu(menu, flags, id, title);
                }
            }
            return menu;
        }
        var root = MakeMenu(BuildMenu());
        uint selected;
        try
        {
            Native.GetCursorPos(out var pointer);
            Native.SetForegroundWindow(source.Handle);
            selected = Native.TrackPopupMenuEx(root, 0x100 | 0x2, pointer.X, pointer.Y, source.Handle, 0);
            Native.PostMessage(source.Handle, 0, 0, 0);
        }
        finally { Native.DestroyMenu(root); }
        if (actions.TryGetValue(selected, out var click))
            Dispatcher.CurrentDispatcher.BeginInvoke(click);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        SetEscape(null);
        Theme.Changed -= RefreshIcon;
        if (added) Native.Shell_NotifyIcon(2, ref data);
        if (data.Icon != 0) Native.DestroyIcon(data.Icon);
        source.RemoveHook(WindowProc);
        source.Dispose();
    }
}
