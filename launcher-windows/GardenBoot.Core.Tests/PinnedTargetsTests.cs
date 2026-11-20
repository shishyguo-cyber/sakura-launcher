namespace GardenBoot.Core.Tests;

public static class PinnedTargetsTests
{
    private static LaunchTarget Target(string name, string? animation, bool enabled = true) =>
        new() { Id = name.ToLowerInvariant(), Name = name, Enabled = enabled, Animation = animation };

    [Test] public static void OnlyEnabledAppsPinnedToAnotherAnimationAreReported()
    {
        var targets = new[] { Target("ChatGPT", "raiden-garden"), Target("Notes", null), Target("Mail", "sakura-greeting"), Target("Off", "raiden-garden", false) };
        Check.Sequence(["ChatGPT"], PinnedTargets.Unaffected("sakura-greeting", targets).Select(t => t.Name));
        Check.Sequence(["Mail"], PinnedTargets.Unaffected("raiden-garden", targets).Select(t => t.Name));
        Check.Equal(0, PinnedTargets.Unaffected(null, [Target("Notes", null)]).Count);
    }

    [Test] public static void FollowCurrentClearsEveryChoice()
    {
        var targets = new List<LaunchTarget> { Target("ChatGPT", "raiden-garden"), Target("Off", "x", false) };
        PinnedTargets.FollowCurrent(targets);
        Check.True(targets.All(t => t.Animation is null));
        Check.Sequence(["True", "False"], targets.Select(t => t.Enabled.ToString()));
    }

    [Test] public static void HintNamesAppsAndPacks()
    {
        var names = new Dictionary<string, string> { ["raiden-garden"] = "雷电将军 · 花园", ["demo-garden"] = "花园 · 占位示例" };
        string Name(string id) => names.GetValueOrDefault(id, id);
        Check.Equal<string?>(null, PinnedTargets.Hint([], Name));
        Check.Equal("ChatGPT 单独指定了「雷电将军 · 花园」，不跟随切换。", PinnedTargets.Hint([Target("ChatGPT", "raiden-garden")], Name));
        Check.Equal("A 单独指定了「雷电将军 · 花园」，B 单独指定了「花园 · 占位示例」，另有 1 个应用也单独指定了动画，不跟随切换。",
            PinnedTargets.Hint([Target("A", "raiden-garden"), Target("B", "demo-garden"), Target("C", "gone")], Name));
    }
}
