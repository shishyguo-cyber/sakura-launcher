namespace GardenBoot.Core;

/// <summary>
/// Apps with their own animation (TARGETS.md <c>animation</c>) are not affected when the user switches the current
/// animation. The settings window and the tray menu say so and offer to let them follow it again (same as macOS).
/// </summary>
public static class PinnedTargets
{
    /// <summary>Enabled apps whose own animation is something other than <paramref name="activeId"/>.</summary>
    public static List<LaunchTarget> Unaffected(string? activeId, IEnumerable<LaunchTarget> targets) =>
        targets.Where(t => t.Enabled && t.Animation is not null && t.Animation != activeId).ToList();

    /// <summary>Clears every per-app choice in place, so all apps follow the current animation.</summary>
    public static void FollowCurrent(IEnumerable<LaunchTarget> targets)
    {
        foreach (var target in targets) target.Animation = null;
    }

    /// <summary>e.g. "ChatGPT 单独指定了「雷电将军 · 花园」，不跟随切换。" (at most two names, then a count).</summary>
    public static string? Hint(IReadOnlyList<LaunchTarget> pinned, Func<string, string> packName)
    {
        if (pinned.Count == 0) return null;
        var named = string.Join("，", pinned.Take(2).Select(t => $"{t.Name} 单独指定了「{packName(t.Animation ?? "")}」"));
        var more = pinned.Count > 2 ? $"，另有 {pinned.Count - 2} 个应用也单独指定了动画" : "";
        return named + more + "，不跟随切换。";
    }
}
