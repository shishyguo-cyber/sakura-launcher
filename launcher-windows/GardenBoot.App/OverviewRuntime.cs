using GardenBoot.Core;

namespace GardenBoot.App;

internal sealed record OverviewTarget(string Id, string Name)
{
    public override string ToString() => Name;
}
internal sealed record OverviewSnapshot(IReadOnlyList<OverviewTarget> Targets, string? SelectedId,
                                         PlaybackStatusReason Reason, bool Connected = true);

internal interface IOverviewRuntime
{
    bool WelcomeDismissed { get; }
    void SetWelcomeDismissed(bool value);
    OverviewSnapshot Overview(string? targetId);
    void PerformOverviewAction(string action);
}
