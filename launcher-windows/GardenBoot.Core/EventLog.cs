using System.Globalization;
using System.Text;

namespace GardenBoot.Core;

/// <summary>
/// Append-only diagnostic log, one timestamped line per event, rotated to <c>events.previous.log</c> past
/// <see cref="Limit"/> bytes. Records event names, process ids and reasons only — never chat content or frames.
/// </summary>
public sealed class EventLog(string directory, long limit = 512 * 1024)
{
    public const string FileName = "events.log";
    public const string PreviousFileName = "events.previous.log";
    private readonly Lock gate = new();

    public string Directory { get; } = directory;
    public long Limit { get; } = limit;
    public string Path => System.IO.Path.Combine(Directory, FileName);
    public string PreviousPath => System.IO.Path.Combine(Directory, PreviousFileName);

    public void Write(string evt) => Write(evt, DateTimeOffset.Now);

    public void Write(string evt, DateTimeOffset at)
    {
        var line = Encoding.UTF8.GetBytes(at.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", CultureInfo.InvariantCulture) + " " + evt + "\n");
        lock (gate)
        {
            try
            {
                System.IO.Directory.CreateDirectory(Directory);
                var current = new FileInfo(Path);
                if (current.Exists && current.Length + line.Length > Limit)
                {
                    File.Move(Path, PreviousPath, overwrite: true);
                }
                using var stream = new FileStream(Path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                stream.Write(line);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
