using GardenBoot.Core;

namespace GardenBoot.App;

internal sealed record OverviewTarget(string Id, string Name)
{
    public override string ToString() => Name;
}
internal sealed record OverviewSnapshot(IReadOnlyList<OverviewTarget> Targets, string? SelectedId,
                                         PlaybackStatusReason Reason, bool Connected = true);
internal sealed record UpdateOverview(string Version, bool Automatic, bool Checking = false,
    string Message = "尚未检查更新", string? AvailableVersion = null, bool Connected = true, bool Installing = false);

internal interface IOverviewRuntime
{
    UpdateOverview UpdateOverview();
    void CheckForUpdatesFromSettings();
    void SetAutomaticUpdates(bool value);
    void OpenUpdateDownload();
    void OpenUpdateFallback() {}
    bool WelcomeDismissed { get; }
    void SetWelcomeDismissed(bool value);
    OverviewSnapshot Overview(string? targetId);
    void PerformOverviewAction(string action);
}
