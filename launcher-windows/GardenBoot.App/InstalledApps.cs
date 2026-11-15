using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>One entry of the Start menu's app list that Sakura can watch.</summary>
internal sealed record InstalledApp(string Name, WindowsTargetIdentity Identity, string Detail, ImageSource? Icon)
{
    public string Key => TargetRules.WindowsKey(Identity);
}

/// <summary>
/// Reads <c>shell:AppsFolder</c> (every app in the Start menu, Store apps included) on a background MTA thread
/// (launcher-spec/TARGETS.md §4). Packaged apps become <c>package</c> targets; desktop apps their exe path.
/// </summary>
internal static class InstalledApps
{
    private static Task<IReadOnlyList<InstalledApp>>? cached;
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, ImageSource> Icons = new(StringComparer.Ordinal);

    /// <summary>Loads once per process; later calls reuse the result.</summary>
    public static Task<IReadOnlyList<InstalledApp>> LoadAsync() => cached ??= Run();

    /// <summary>The icon of an already listed app, if the list has been read.</summary>
    public static ImageSource? IconFor(WindowsTargetIdentity identity) =>
        Icons.GetValueOrDefault(TargetRules.WindowsKey(identity)) ?? (identity.Package is { } package ? Icons.GetValueOrDefault(PackageKey(package)) : null);

    /// <summary>The key of a whole package (no exe), how the Start menu lists packaged apps.</summary>
    public static string PackageKey(string package) => TargetRules.WindowsKey(new() { Package = package });

    /// <summary>Keys under which a target counts as "already added" in the picker.</summary>
    public static IEnumerable<string> AddedKeys(WindowsTargetIdentity identity)
    {
        yield return TargetRules.WindowsKey(identity);
        if (identity.Package is { } package) yield return PackageKey(package);
    }

    private static Task<IReadOnlyList<InstalledApp>> Run()
    {
        var done = new TaskCompletionSource<IReadOnlyList<InstalledApp>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { done.SetResult(Enumerate()); }
            catch (Exception e) { done.SetException(e); }
        }) { IsBackground = true, Name = "Sakura installed apps" };
        thread.SetApartmentState(ApartmentState.MTA); // an STA without a message loop deadlocked (measured: no result in 30 s)
        thread.Start();
        // No continuation on the caller's context: a UI context may run posts at a low priority (seen in tests).
        return done.Task;
    }

    private static IReadOnlyList<InstalledApp> Enumerate()
    {
        var self = Environment.ProcessPath;
        var result = new Dictionary<string, InstalledApp>(StringComparer.Ordinal);
        var folderId = typeof(IShellItem2).GUID;
        Shell.SHCreateItemFromParsingName("shell:AppsFolder", 0, ref folderId, out var folder);
        var bhid = Shell.EnumItems; var enumId = typeof(IEnumShellItems).GUID;
        folder.BindToHandler(0, ref bhid, ref enumId, out var enumPointer);
        var items = (IEnumShellItems)Marshal.GetObjectForIUnknown(enumPointer);
        Marshal.Release(enumPointer);
        while (items.Next(1, out var raw, out var fetched) == 0 && fetched == 1)
        {
            try
            {
                if (raw is not IShellItem2 item) continue;
                var name = DisplayName(item, 0)?.Trim();
                if (string.IsNullOrEmpty(name)) continue;
                var aumid = StringProperty(item, Shell.AppUserModelId);
                var link = StringProperty(item, Shell.LinkTargetParsingPath);
                var parsing = DisplayName(item, unchecked((int)0x80018001)); // SIGDN_PARENTRELATIVEPARSING
                var identity = Identify(aumid, link, parsing);
                if (identity is null) continue;
                if (identity.Path is { } path && self is not null && string.Equals(path, self, StringComparison.OrdinalIgnoreCase)) continue;
                var app = new InstalledApp(name, identity, identity.Path ?? identity.Package!, Icon(item));
                if (result.TryAdd(app.Key, app) && app.Icon is { } icon) Icons[app.Key] = icon;
            }
            catch (Exception e) when (e is COMException or ArgumentException or InvalidCastException or IOException) { }
            finally { if (raw is not null) Marshal.ReleaseComObject(raw); }
        }
        Marshal.ReleaseComObject(items);
        Marshal.ReleaseComObject(folder);
        return result.Values.OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>Store/packaged app → package name; desktop app → the exe its shortcut points to. Null when neither is known.</summary>
    internal static WindowsTargetIdentity? Identify(string? aumid, string? linkTarget, string? parsingName)
    {
        var exe = ExePath(linkTarget) ?? ExePath(parsingName);
        if (exe is not null) return new() { Path = exe };
        if (aumid is { } id && id.IndexOf('!') is > 0 and var bang)
        {
            var family = id[..bang];
            var underscore = family.IndexOf('_');
            var package = underscore > 0 ? family[..underscore] : family;
            if (package.Length > 0) return new() { Package = package };
        }
        return null;
    }

    private static string? ExePath(string? candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate)) return null;
        var path = candidate.Trim();
        // "{GUID}\sub\app.exe" = a known folder (Program Files etc.) plus a relative path.
        if (path.StartsWith('{') && path.IndexOf('}') is > 0 and var close && Guid.TryParse(path[1..close], out var known)
            && Shell.SHGetKnownFolderPath(ref known, 0, 0, out var folder) == 0)
        {
            var root = Marshal.PtrToStringUni(folder); Marshal.FreeCoTaskMem(folder);
            path = Path.Combine(root ?? "", path[(close + 1)..].TrimStart('\\'));
        }
        return path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && Path.IsPathFullyQualified(path) && File.Exists(path) ? path : null;
    }

    private static string? DisplayName(IShellItem2 item, int sigdn)
    {
        try
        {
            item.GetDisplayName(sigdn, out var pointer);
            var text = Marshal.PtrToStringUni(pointer); Marshal.FreeCoTaskMem(pointer);
            return text;
        }
        catch (COMException) { return null; }
    }

    private static string? StringProperty(IShellItem2 item, Shell.PropertyKey key)
    {
        if (item.GetString(ref key, out var pointer) != 0 || pointer == 0) return null;
        var text = Marshal.PtrToStringUni(pointer); Marshal.FreeCoTaskMem(pointer);
        return text;
    }

    /// <summary>32 px icon with its alpha channel (CreateBitmapSourceFromHBitmap would drop it).</summary>
    private static ImageSource? Icon(IShellItem2 item)
    {
        if (item is not IShellItemImageFactory factory) return null;
        if (factory.GetImage(new Shell.Size { Width = 32, Height = 32 }, 0x4 /* ICONONLY */, out var bitmap) != 0 || bitmap == 0) return null;
        try
        {
            var header = new Native.BitmapInfoHeader { Size = (uint)Marshal.SizeOf<Native.BitmapInfoHeader>(), Width = 32, Height = -32, Planes = 1, BitCount = 32 };
            var pixels = new byte[32 * 32 * 4];
            var dc = Shell.GetDC(0);
            try { if (Shell.GetDIBits(dc, bitmap, 0, 32, pixels, ref header, 0) == 0) return null; }
            finally { Shell.ReleaseDC(0, dc); }
            var source = BitmapSource.Create(32, 32, 96, 96, PixelFormats.Pbgra32, null, pixels, 32 * 4);
            source.Freeze();
            return source;
        }
        finally { Native.DeleteObject(bitmap); }
    }
}

[ComImport, Guid("7e9fb0d3-919f-4307-ab2e-9b1860310c93"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellItem2
{
    // IShellItem
    void BindToHandler(nint bindContext, ref Guid handler, ref Guid interfaceId, out nint result);
    void GetParent(out nint parent);
    void GetDisplayName(int sigdn, out nint name);
    void GetAttributes(uint mask, out uint attributes);
    void Compare(nint other, uint hint, out int order);
    // IShellItem2
    void GetPropertyStore(int flags, ref Guid interfaceId, out nint result);
    void GetPropertyStoreWithCreateObject(int flags, nint createObject, ref Guid interfaceId, out nint result);
    void GetPropertyStoreForKeys(nint keys, uint count, int flags, ref Guid interfaceId, out nint result);
    void GetPropertyDescriptionList(ref Shell.PropertyKey type, ref Guid interfaceId, out nint result);
    void Update(nint bindContext);
    void GetProperty(ref Shell.PropertyKey key, nint value);
    void GetCLSID(ref Shell.PropertyKey key, out Guid clsid);
    void GetFileTime(ref Shell.PropertyKey key, out long time);
    void GetInt32(ref Shell.PropertyKey key, out int value);
    [PreserveSig] int GetString(ref Shell.PropertyKey key, out nint value);
}

[ComImport, Guid("70629033-e363-4a28-a567-0db78006e6d7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IEnumShellItems
{
    [PreserveSig] int Next(uint count, [MarshalAs(UnmanagedType.Interface)] out object item, out uint fetched);
}

[ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellItemImageFactory
{
    [PreserveSig] int GetImage(Shell.Size size, int flags, out nint bitmap);
}

internal static class Shell
{
    [StructLayout(LayoutKind.Sequential)] internal struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Sequential)] internal struct Size { public int Width, Height; }
    internal static readonly Guid EnumItems = new("94f60519-2850-4924-aa5a-d15e84868039");
    internal static PropertyKey AppUserModelId = new() { Format = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };
    internal static PropertyKey LinkTargetParsingPath = new() { Format = new("B9B4B3FC-2B51-4A42-B5D8-324146AFCF25"), Id = 2 };

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    internal static extern void SHCreateItemFromParsingName(string path, nint bindContext, ref Guid interfaceId, out IShellItem2 item);
    [DllImport("shell32.dll")] internal static extern int SHGetKnownFolderPath(ref Guid id, uint flags, nint token, out nint path);
    [DllImport("user32.dll")] internal static extern nint GetDC(nint window);
    [DllImport("user32.dll")] internal static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll")] internal static extern int GetDIBits(nint dc, nint bitmap, uint start, uint lines, byte[] bits, ref Native.BitmapInfoHeader info, uint usage);
}
