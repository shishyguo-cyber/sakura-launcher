namespace GardenBoot.Core;

public sealed class ExperienceStore(string directory)
{
    public string Path => System.IO.Path.Combine(directory, "experience.json");
    public ExperienceSettings Load() => File.Exists(Path) ? ExperienceSettings.Parse(File.ReadAllText(Path)) : new();
    public void Save(ExperienceSettings settings)
    {
        var json = settings.ToJson();
        Directory.CreateDirectory(directory);
        if (File.Exists(Path))
        {
            var previous = File.ReadAllText(Path);
            try { ExperienceSettings.Parse(previous); }
            catch (ExperienceException e) when (!e.FutureVersion)
            { File.Copy(Path, System.IO.Path.Combine(directory, $"experience.recovery-{Guid.NewGuid()}.json")); }
        }
        var temporary = System.IO.Path.Combine(directory, $".experience-{Guid.NewGuid()}.tmp");
        try { File.WriteAllText(temporary, json); File.Move(temporary, Path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
