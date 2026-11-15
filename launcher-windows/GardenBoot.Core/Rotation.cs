namespace GardenBoot.Core;

/// <summary>Which pack automatic playback uses (launcher-spec/SCHEDULE-AND-LIBRARY.md §3).</summary>
public enum PackRotation { Fixed, ShuffleAll, ShuffleFavorites }

public static class PackRotationRules
{
    public static string LogName(this PackRotation rotation) => rotation switch
    {
        PackRotation.Fixed => "fixed", PackRotation.ShuffleAll => "shuffleAll", _ => "shuffleFavorites",
    };

    /// <summary>Playable pack ids in ordinal order, the order both platforms feed to <see cref="Choose"/>.</summary>
    public static IReadOnlyList<string> AvailableIds(IEnumerable<InstalledPack> packs) =>
        packs.Select(p => p.Id).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList();

    /// <param name="random">A value in [0, 1); 1 is clamped to the last candidate.</param>
    public static string? Choose(PackRotation rotation, IReadOnlyCollection<string> favorites, IReadOnlyList<string> available,
                                 string? active, string? lastPackId, double random)
    {
        if (rotation == PackRotation.Fixed) return active;
        var candidates = rotation == PackRotation.ShuffleAll
            ? available.ToList()
            : available.Where(id => favorites.Contains(id, StringComparer.Ordinal)).ToList();
        if (candidates.Count == 0) return active;
        if (candidates.Count > 1 && lastPackId is not null) candidates.Remove(lastPackId);
        var r = double.IsFinite(random) ? Math.Clamp(random, 0, 1) : 0;
        return candidates[Math.Min((int)Math.Floor(r * candidates.Count), candidates.Count - 1)];
    }
}
