using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using FaceSwapBootstrap;

public static class BootstrapTests {
    sealed class Quiet : IProgress<Status> { public void Report(Status value) { } }
    sealed class Server : IDisposable {
        readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        readonly byte[] bytes;
        readonly string mode;
        volatile bool stopped;
        public int Requests;
        public string LastRange;
        public string Url;
        public Server(byte[] content, string value) {
            bytes = content; mode = value; listener.Start(); Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/asset";
            Task.Run(() => {
                while (!stopped) {
                    try { using (var client = listener.AcceptTcpClient()) using (var stream = client.GetStream()) {
                        var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
                        string line; LastRange = null;
                        while (!String.IsNullOrEmpty(line = reader.ReadLine())) if (line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase)) LastRange = line.Substring(6).Trim();
                        int count = Interlocked.Increment(ref Requests);
                        int offset = LastRange == null ? 0 : Int32.Parse(LastRange.Substring(6).TrimEnd('-'));
                        bool partial = (offset > 0 || mode == "segments") && mode != "ignore";
                        if (!partial) offset = 0;
                        int end = mode == "segments" ? Math.Min(bytes.Length - 1, offset + 511) : bytes.Length - 1;
                        string headers = "HTTP/1.1 " + (partial ? "206 Partial Content" : "200 OK") + "\r\nConnection: close\r\nContent-Length: " + (end - offset + 1) + "\r\n";
                        if (partial) headers += "Content-Range: bytes " + (mode == "bad-range" ? 0 : offset) + "-" + end + "/" + bytes.Length + "\r\n";
                        byte[] header = Encoding.ASCII.GetBytes(headers + "\r\n"); stream.Write(header, 0, header.Length);
                        int length = mode == "truncate" && count == 1 ? 1024 : end - offset + 1;
                        byte[] body = mode == "corrupt" ? new byte[bytes.Length] : bytes;
                        stream.Write(body, offset, length); stream.Flush();
                    } } catch { if (stopped) break; }
                }
            });
        }
        public void Dispose() { stopped = true; listener.Stop(); }
    }
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Reject(Action action, string message) { bool failed = false; try { action(); } catch { failed = true; } Check(failed, message); }
    static string BytesHash(byte[] bytes) { using (var hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
    static Asset MakeAsset(byte[] bytes, string url) { return new Asset { name = "asset.bin", size = bytes.Length, sha256 = BytesHash(bytes), urls = new[] { url } }; }
    static int passes;
    static void Run(string name, Action test) { test(); passes++; Console.WriteLine("PASS " + name); }
    public static int Main(string[] args) {
        if (args.Length == 2) {
            try {
                var manifest = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 }.Deserialize<Manifest>(File.ReadAllText(args[0], Encoding.UTF8));
                Console.WriteLine(Core.Prepare(Path.GetFullPath(args[1]), manifest, CancellationToken.None, new Quiet()));
                return 0;
            } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        }
        string root = Path.Combine(Path.GetTempPath(), "Vox启动器测试-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            Run("路径穿越与重复路径保护", () => { foreach (string name in new[] { "../a", "a/../../b", "C:/a", "a\\b", "a/.", "a. /b" }) Reject(() => Core.SafePath(root, name), name); });
            byte[] content = Encoding.UTF8.GetBytes(String.Concat(Enumerable.Repeat("可信桌面资源", 6000)));
            var quiet = new Quiet();
            Run("续传与完成文件零下载复用", () => {
                string directory = Path.Combine(root, "resume"); Directory.CreateDirectory(directory);
                using (var server = new Server(content, "range")) {
                    var asset = MakeAsset(content, server.Url); string target = Path.Combine(directory, asset.name);
                    File.WriteAllBytes(target + ".part", content.Take(513).ToArray()); Core.Download(asset, directory, CancellationToken.None, quiet, true);
                    Check(server.LastRange == "bytes=513-" && Core.Verified(target, asset), "未正确续传");
                    int requests = server.Requests; Core.Download(asset, directory, CancellationToken.None, quiet, true); Check(server.Requests == requests, "完整缓存不应联网");
                }
            });
            Run("忽略 Range 时覆盖重下", () => {
                string directory = Path.Combine(root, "ignored"); Directory.CreateDirectory(directory);
                using (var server = new Server(content, "ignore")) {
                    var asset = MakeAsset(content, server.Url); File.WriteAllBytes(Path.Combine(directory, asset.name) + ".part", content.Take(20).ToArray());
                    Core.Download(asset, directory, CancellationToken.None, quiet, true); Check(Core.Verified(Path.Combine(directory, asset.name), asset), "重复追加字节");
                }
            });
            Run("截断下载自动续接", () => {
                using (var server = new Server(content, "truncate")) { var asset = MakeAsset(content, server.Url); Core.Download(asset, Path.Combine(root, "truncated"), CancellationToken.None, quiet, true); Check(server.Requests == 2 && server.LastRange == "bytes=1024-", "没有续接分片"); }
            });
            Run("分段 CDN 自动续接直到完整", () => {
                using (var server = new Server(content, "segments")) {
                    var asset = MakeAsset(content, server.Url); string directory = Path.Combine(root, "segments");
                    Core.Download(asset, directory, CancellationToken.None, quiet, true);
                    Check(server.Requests > 2 && Core.Verified(Path.Combine(directory, asset.name), asset), "分段响应未能完整续接");
                }
            });
            Run("哈希错误不生成完成文件", () => {
                using (var server = new Server(content, "corrupt")) { var asset = MakeAsset(content, server.Url); string dir = Path.Combine(root, "corrupt"); Reject(() => Core.Download(asset, dir, CancellationToken.None, quiet, true), "错误哈希通过"); Check(!File.Exists(Path.Combine(dir, asset.name)), "损坏文件成为完成文件"); }
            });
            Run("错误续传范围被拒绝", () => {
                string dir = Path.Combine(root, "bad-range"); Directory.CreateDirectory(dir);
                using (var server = new Server(content, "bad-range")) { var asset = MakeAsset(content, server.Url); File.WriteAllBytes(Path.Combine(dir, asset.name) + ".part", content.Take(9).ToArray()); Reject(() => Core.Download(asset, dir, CancellationToken.None, quiet, true), "错误 Range 通过"); }
            });
            Run("取消与默认 HTTPS 限制", () => {
                using (var server = new Server(content, "range")) {
                    var asset = MakeAsset(content, server.Url); var cancel = new CancellationTokenSource(); cancel.Cancel();
                    Reject(() => Core.Download(asset, Path.Combine(root, "cancel"), cancel.Token, quiet, true), "取消未生效");
                    Reject(() => Core.Download(asset, Path.Combine(root, "http"), CancellationToken.None, quiet), "非 HTTPS 未被拒绝"); Check(server.Requests == 0, "不应发送请求");
                }
            });
            Run("ZIP 完整校验和越界拒绝", () => {
                string archive = Path.Combine(root, "desktop.zip"); var file = MakeAsset(content, "https://example.com"); file.name = "file.bin";
                var manifest = new Manifest { files = new[] { file } };
                using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create)) { zip.CreateEntry("bundle/"); using (var stream = zip.CreateEntry("bundle/file.bin").Open()) stream.Write(content, 0, content.Length); }
                string stage = Path.Combine(root, "stage"); Directory.CreateDirectory(stage); Core.Extract(archive, stage, manifest, CancellationToken.None); Check(Core.Verified(Path.Combine(stage, "file.bin"), file), "解压校验失败");
                string evil = Path.Combine(root, "evil.zip"); using (var zip = ZipFile.Open(evil, ZipArchiveMode.Create)) using (var stream = zip.CreateEntry("bundle/../../escape.bin").Open()) stream.Write(content, 0, content.Length);
                Reject(() => Core.Extract(evil, Path.Combine(root, "stage2"), manifest, CancellationToken.None), "ZIP 越界通过");
            });
            Run("应用升级后保留新版并继续校验桌面核心", () => {
                string directory = Path.Combine(root, "updated"); Directory.CreateDirectory(Path.Combine(directory, "faceswap studio/bridge"));
                Directory.CreateDirectory(Path.Combine(directory, "updater")); Directory.CreateDirectory(Path.Combine(directory, "faceswap studio/runtime/windows_app/current"));
                string executable = Path.Combine(directory, "启动FaceSwap Studio.exe"); File.WriteAllBytes(executable, content);
                File.WriteAllText(Path.Combine(directory, "VERSION"), "2.0.3");
                File.WriteAllText(Path.Combine(directory, "update-config.json"), "{\"releaseId\":\"20261019000000\"}");
                File.WriteAllText(Path.Combine(directory, "updater/transaction.py"), "new");
                File.WriteAllText(Path.Combine(directory, "faceswap studio/bridge/app_server.py"), "new");
                File.WriteAllText(Path.Combine(directory, "faceswap studio/runtime/windows_app/current/faceswap_studio.exe"), "new");
                var asset = MakeAsset(content, "https://example.com"); asset.name = "启动FaceSwap Studio.exe";
                var manifest = new Manifest { appVersion = "2.0.2", appReleaseId = "20261018000000", entry = asset.name, files = new[] { asset } };
                Check(Core.DesktopReady(directory, manifest, CancellationToken.None), "不应还原成旧版");
                File.WriteAllBytes(executable, new byte[content.Length]);
                Reject(() => Core.DesktopReady(directory, manifest, CancellationToken.None), "桌面核心损坏应被拒绝");
                Check(File.ReadAllText(Path.Combine(directory, "VERSION")).Contains("2.0.3"), "新版配置不应被覆盖");
            });
            Console.WriteLine(passes + " native bootstrap tests passed"); return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally {
            string resolved = Path.GetFullPath(root);
            if (Path.GetDirectoryName(resolved).TrimEnd(Path.DirectorySeparatorChar) == Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar) && Path.GetFileName(resolved).StartsWith("Vox启动器测试-")) Directory.Delete(resolved, true);
        }
    }
}
