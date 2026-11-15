namespace GardenBoot.Core;

public static class PlaybackPolicy
{
    /// <summary>While the overlay is this young, other apps flickering to the foreground are part of the launch.</summary>
    public const double ActivationGrace = 1.5;

    public static bool ShouldAutoPlay(bool paused, bool reduceMotion, bool playDespiteReduceMotion) =>
        !paused && (!reduceMotion || playDespiteReduceMotion);

    /// <summary>Whether another app coming to the foreground should end playback as "user switched away".</summary>
    public static bool EndsOnActivation(bool isLauncher, bool isTarget, double overlayAge) =>
        !isLauncher && !isTarget && overlayAge >= ActivationGrace;

    /// <summary>Hand focus back only if the user is still on the overlay or the target, and the target is alive.</summary>
    public static bool ShouldReturnFocus(int? foregroundPid, int launcherPid, IReadOnlySet<int> targetPids, bool targetAlive) =>
        targetAlive && foregroundPid is { } pid && (pid == launcherPid || targetPids.Contains(pid));
}

public enum LaunchSkip { Hidden, AtLogin }

/// <summary>Launches that should not get an animation at all.</summary>
public static class LaunchFilter
{
    /// <summary>How long after a login-session start the launcher ignores target launches.</summary>
    public const double LoginGrace = 45;
    /// <summary>A launcher started this soon after boot is treated as started at login.</summary>
    public const double BootWindow = 180;

    public static string LogName(this LaunchSkip skip) => skip == LaunchSkip.Hidden ? "hidden" : "at-login";

    public static LaunchSkip? Skip(bool targetHidden, double launcherAge, bool launcherStartedAtLogin, double systemUptime)
    {
        if (targetHidden) return LaunchSkip.Hidden;
        var uptimeAtLauncherStart = systemUptime - launcherAge;
        var loginSession = launcherStartedAtLogin || uptimeAtLauncherStart < BootWindow;
        return loginSession && launcherAge < LoginGrace ? LaunchSkip.AtLogin : null;
    }
}
