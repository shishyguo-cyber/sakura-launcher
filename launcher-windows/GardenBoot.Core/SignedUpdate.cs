using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.IO.Compression;
using System.Diagnostics;

namespace GardenBoot.Core;
public static class SignedUpdate
{
    public sealed class Failure(string code, string message, Exception? inner = null) : IOException(message, inner)
    {
        public string Code { get; } = code;
    }
    public sealed class RecoveryRequired(string backup, Exception inner) : IOException($"自动恢复未完成，旧版保留于：{backup}。请手动恢复或去 GitHub 下载。", inner);
    public const string PublicKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAELfF7XIzY6fqIOYOf7aN5SViuJ7PKHuKfsTPVCCp2EQv1yceqVYpgpHPG/ksrrPI9Qb/taY3F45xepyT4zB5ntA==";
    public const long MaxArchive = 512L * 1024 * 1024, MaxExpanded = 2L * 1024 * 1024 * 1024;
    public static Uri Asset(string version, string current, string platform)
    {
        if (UpdateRules.Parse(version)?.Text != version || (UpdateRules.Compare(version, current) ?? 0) <= 0 || platform is not ("macOS" or "windows-x64")) throw new Failure("version", "版本无效或不是更新版本。");
        return new($"https://github.com/shishyguo-cyber/sakura-launcher/releases/download/v{version}/Sakura-{version}-{platform}.zip");
    }
    public static void Verify(string manifest, byte[] payload, string version, string current, string platform)
    {
        _ = Asset(version, current, platform);
        try
        {
            if (manifest.Length > 16384) throw new Failure("signature", "更新签名验证失败。");
            using var d = JsonDocument.Parse(manifest); var m = d.RootElement;
            string S(string key) => m.GetProperty(key).GetString()!;
            var count = m.GetProperty("bytes").GetInt64(); var sha = S("sha256");
            if (m.GetProperty("format").GetInt32() != 1 || S("version") != version || S("platform") != platform || count <= 0 || count > MaxArchive || sha.Length != 64 || !sha.All(c => "0123456789abcdef".Contains(c))) throw new Failure("signature", "更新签名验证失败。");
            using var key = ECDsa.Create(); key.ImportSubjectPublicKeyInfo(Convert.FromBase64String(PublicKey), out _);
            var message = Encoding.UTF8.GetBytes($"Sakura Update v1\n{version}\n{platform}\n{count}\n{sha}\n");
            if (!key.VerifyData(message, Convert.FromBase64String(S("signature")), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)) throw new Failure("signature", "更新签名验证失败。");
            if (payload.LongLength != count || Convert.ToHexStringLower(SHA256.HashData(payload)) != sha) throw new Failure("corrupt", "更新文件损坏或下载不完整。");
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException or CryptographicException or NullReferenceException)
        { throw new Failure("signature", "更新签名验证失败。", e); }
    }

    public static async Task Download(Uri url, string destination, long limit, Action<double> progress, CancellationToken token, Uri? testOrigin = null)
    {
        bool Allowed(Uri u) => u.UserInfo.Length == 0 && (u.Scheme == "https" && u.IsDefaultPort && (u.Host == "release-assets.githubusercontent.com" || (u.Host == "github.com" && u.AbsolutePath.StartsWith("/shishyguo-cyber/sakura-launcher/releases/download/", StringComparison.Ordinal))) || testOrigin is not null && u.Scheme == "http" && u.Host == "127.0.0.1" && u.Port == testOrigin.Port);
        using var handler = new System.Net.Http.HttpClientHandler { AllowAutoRedirect = false };
        using var client = new System.Net.Http.HttpClient(handler) { Timeout = TimeSpan.FromMinutes(30) };
        for (int redirects = 0; redirects < 6; redirects++)
        {
            if (!Allowed(url)) throw new InvalidDataException("更新下载地址不受信任。");
            using var response = await client.GetAsync(url, System.Net.Http.HttpCompletionOption.ResponseHeadersRead, token);
            if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } location) { url = new Uri(url, location); continue; }
            response.EnsureSuccessStatusCode();
            var expected = response.Content.Headers.ContentLength;
            if (expected > limit) throw new InvalidDataException("更新包过大。");
            await using var input = await response.Content.ReadAsStreamAsync(token);
            await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var buffer = new byte[65536]; long total = 0; int n;
            while ((n = await input.ReadAsync(buffer, token)) > 0)
            {
                total += n; if (total > limit) throw new InvalidDataException("更新包过大。");
                await output.WriteAsync(buffer.AsMemory(0, n), token); progress(expected > 0 ? (double)total / expected.Value : -1);
            }
            if (expected is not null && total != expected) throw new IOException("更新下载不完整。");
            return;
        }
        throw new IOException("更新重定向次数过多。");
    }
    public sealed record Request(string Target, string Staged, string Work, string Version, int Parent, string[] Arguments);
    public static string Prepare(string zip, string signature, string target, string version, string current, string work, string[]? arguments = null)
    {
        target = Path.GetFullPath(target).TrimEnd(Path.DirectorySeparatorChar);
        var parent = Path.GetDirectoryName(target)!;
        if ((File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0) throw new IOException("请在普通可写目录中安装 Sakura。");
        var probe = Path.Combine(parent, ".sakura-write-" + Guid.NewGuid()); Directory.CreateDirectory(probe); Directory.Delete(probe);
        if (new DriveInfo(Path.GetPathRoot(parent)!).AvailableFreeSpace < 5L * 1024 * 1024 * 1024) throw new IOException("磁盘空间不足，请至少留出 5 GB。");
        var payload = File.ReadAllBytes(zip); Verify(File.ReadAllText(signature), payload, version, current, "windows-x64");
        var staged = Path.Combine(parent, ".Sakura-update-" + Guid.NewGuid());
        try
        {
            using var archive = new ZipArchive(new MemoryStream(payload)); long expanded = 0; var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var e in archive.Entries)
            {
                var name = e.FullName;
                if (!name.StartsWith("Sakura/", StringComparison.Ordinal) || name.Contains('\\') || name.Contains(':') || name.Contains('\0') || name.Split('/').Any(p => p is ".." or "." || p.EndsWith('.') || p.EndsWith(' ') || new[] { "CON", "PRN", "AUX", "NUL", "COM1", "LPT1" }.Contains(p.Split('.')[0].ToUpperInvariant())) || !names.Add(name) || ((e.ExternalAttributes >> 16) & 0xf000) == 0xa000) throw new InvalidDataException("更新包包含不安全的路径。");
                expanded += e.Length; if (expanded > MaxExpanded) throw new IOException("解压空间不足。");
            }
            Directory.CreateDirectory(staged);
            foreach (var e in archive.Entries)
            {
                var relative = e.FullName[7..]; if (relative.Length == 0) continue;
                var destination = Path.Combine(staged, relative.Replace('/', Path.DirectorySeparatorChar));
                if (e.FullName.EndsWith('/')) { Directory.CreateDirectory(destination); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!); e.ExtractToFile(destination);
            }
            var exe = Path.Combine(staged, "Sakura.exe"); var dll = Path.Combine(staged, "Sakura.dll");
            if (!File.Exists(exe) || !File.Exists(dll) || FileVersionInfo.GetVersionInfo(dll).ProductVersion?.Split('+')[0] != version) throw new InvalidDataException("更新包的程序结构或版本不正确。");
            var request = new Request(target, staged, work, version, Environment.ProcessId, arguments ?? []);
            var path = Path.Combine(work, "request.json"); File.WriteAllText(path, JsonSerializer.Serialize(request)); return path;
        }
        catch { if (Directory.Exists(staged)) Directory.Delete(staged, true); throw; }
    }
    public static void Apply(string path)
    {
        var r = JsonSerializer.Deserialize<Request>(File.ReadAllText(path))!;
        try { using var parent = Process.GetProcessById(r.Parent); if (!parent.WaitForExit(30000)) throw new IOException("旧版未退出。"); } catch (ArgumentException) { }
        var backup = r.Staged + ".backup"; var ack = Path.Combine(r.Work, "ready"); bool backed = false, installed = false; Process? child = null;
        Process Start(params string[] args)
        {
            var info = new ProcessStartInfo(Path.Combine(r.Target, "Sakura.exe")) { UseShellExecute = false, WorkingDirectory = r.Target };
            foreach (var a in r.Arguments.Concat(args)) info.ArgumentList.Add(a);
            return Process.Start(info)!;
        }
        try
        {
            Directory.Move(r.Target, backup); backed = true;
            Directory.Move(r.Staged, r.Target); installed = true;
            child = Start("--update-ready", ack, "--settings"); bool ready = false;
            for (int i = 0; i < 300 && !child.HasExited; i++)
            {
                if (File.Exists(ack) && File.ReadAllText(ack) == r.Version) { ready = true; break; }
                Thread.Sleep(100);
            }
            Thread.Sleep(2000);
            if (!ready || child.HasExited) throw new IOException("新版未能正常启动，已恢复旧版。");
            // A running Windows helper cannot delete its own loaded files. Use the built-in shell only
            // for delayed cleanup after this process exits; no service, scheduled task or login item.
            var literal = r.Work.Replace("'", "''");
            var cleanup = $"Start-Sleep -Seconds 3; Remove-Item -LiteralPath '{literal}' -Recurse -Force -ErrorAction SilentlyContinue";
            try {
                var cleaner = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true };
                cleaner.ArgumentList.Add("-NoProfile"); cleaner.ArgumentList.Add("-NonInteractive"); cleaner.ArgumentList.Add("-EncodedCommand");
                cleaner.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(cleanup))); Process.Start(cleaner);
            } catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
            // Backup cleanup failure is harmless and must never roll back a healthy new process.
            try { Directory.Delete(backup, true); Directory.Delete(r.Work, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        catch (Exception error)
        {
            try {
                if (child is { HasExited: false }) { child.Kill(true); child.WaitForExit(); }
                if (installed) Directory.Move(r.Target, r.Staged);
                if (backed) Directory.Move(backup, r.Target);
            } catch (Exception recovery) { throw new RecoveryRequired(backed ? backup : r.Target, recovery); }
            try { File.WriteAllText(Path.Combine(r.Work, "failure"), error.Message); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            try { Start("--update-failed", "--settings"); } catch (Exception reopen) { throw new RecoveryRequired(r.Target, reopen); }
            throw;
        }
    }
}
