using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using GardenBoot.Core;
namespace GardenBoot.Core.Tests;
public static class SignedUpdateTests
{
    [Test] public static void GitHubConnectivityMessagesForCheckAndDownload()
    {
        Exception[] errors = [
            new HttpRequestException(HttpRequestError.NameResolutionError),
            new HttpRequestException(HttpRequestError.ConnectionError),
            new HttpRequestException(HttpRequestError.SecureConnectionError),
            new TaskCanceledException("request timed out", new TimeoutException()),
            new SocketException((int)SocketError.NetworkUnreachable),
            new HttpRequestException("connection refused", new SocketException((int)SocketError.ConnectionRefused)),
            new HttpIOException(HttpRequestError.Unknown, "connection reset", new SocketException((int)SocketError.ConnectionReset)),
        ];
        const string expected = "连不上 GitHub，请确认这台电脑能打开 github.com 后重试。";
        foreach (var error in errors)
        {
            Check.Equal(expected, UpdateRules.CheckFailureMessage(error));
            Check.Equal(expected, SignedUpdate.FailureMessage(error));
        }
    }

    [Test] public static void OtherUpdateErrorsRetainTheirMessages()
    {
        Exception[] errors = [
            new HttpRequestException(HttpRequestError.ConnectionError, "server error", statusCode: HttpStatusCode.ServiceUnavailable),
            new HttpRequestException(HttpRequestError.ProxyTunnelError, "proxy returned an error"),
            new HttpIOException(HttpRequestError.ResponseEnded, "incomplete response"),
            new JsonException("invalid release list"),
            new TaskCanceledException(),
            new SignedUpdate.Failure("signature", "更新签名验证失败。"),
            new IOException("磁盘空间不足，请至少留出 5 GB。"),
            new UnauthorizedAccessException("安装目录不可写。"),
        ];
        foreach (var error in errors)
        {
            Check.Equal("暂时无法检查更新，请稍后再试。", UpdateRules.CheckFailureMessage(error));
            Check.Equal($"更新失败：{error.Message} 可去 GitHub 手动下载。", SignedUpdate.FailureMessage(error));
        }
    }

    [Test] public static void LargePrereleaseAndCanonicalVersions()
    {
        Check.Equal<int?>(1, UpdateRules.Compare("0.2.0-preview.999999999999999999999999", "0.2.0-preview.8"));
        Check.Throws<SignedUpdate.Failure>(() => SignedUpdate.Asset("0.2.0-preview.8+metadata", "0.2.0-preview.7", "windows-x64"));
    }
    [Test] public static void VersionsAndSharedSignatures()
    {
        Check.Throws<SignedUpdate.Failure>(() => SignedUpdate.Asset("0.2.0-preview.7", "0.2.0-preview.7", "windows-x64"));
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "launcher-spec"))) directory = directory.Parent;
        Check.Equal(File.ReadAllText(Path.Combine(directory!.FullName, "launcher-spec/update-public-key.txt")).Trim(), SignedUpdate.PublicKey);
        using var vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory!.FullName, "launcher-spec/conformance/signed-updates.json")));
        foreach (var v in vectors.RootElement.EnumerateArray())
        {
            bool valid; string state;
            try { SignedUpdate.Verify(v.GetProperty("manifest").GetRawText(), Encoding.UTF8.GetBytes(v.GetProperty("payload").GetString()!), v.GetProperty("version").GetString()!, "0.2.0-preview.7", v.GetProperty("platform").GetString()!); valid = true; state = "confirmed";
                Check.Equal(v.GetProperty("asset").GetString(), SignedUpdate.Asset(v.GetProperty("version").GetString()!, "0.2.0-preview.7", v.GetProperty("platform").GetString()!).AbsoluteUri); }
            catch (SignedUpdate.Failure e) { valid = false; state = e.Code; }
            Check.Equal(v.GetProperty("state").GetString(), state);
            Check.Equal(v.GetProperty("valid").GetBoolean(), valid, v.GetProperty("name").GetString()!);
        }
    }
}
