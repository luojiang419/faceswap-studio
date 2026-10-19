using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace FaceSwapBootstrap {
    public sealed class InstallState {
        public string product = "faceswap-studio", id, root, state, version, releaseId, registryKey;
        public string[] files = new string[0], shortcuts = new string[0];
    }
    public sealed class IntegrationPaths {
        public string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        public string startMenu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "易容 Studio");
        public string registryKey = Installer.UninstallKey;
    }
    public sealed class InstallDrive { public string root; public long free; public bool ready; }
    public static class Installer {
        public const string Marker = ".faceswap-install.json";
        public const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\FaceSwapStudio";
        const string SettingsKey = @"Software\FaceSwapStudio\Installer";
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 };
        public static string Canonical(string value) { return Path.GetFullPath(value).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
        public static bool SamePath(string a, string b) { return String.Equals(Canonical(a), Canonical(b), StringComparison.OrdinalIgnoreCase); }
        public const long RequiredSpace = 12L * 1024 * 1024 * 1024;
        public static string DriveProblem(InstallDrive drive, IEnumerable<InstallDrive> all) {
            if (!drive.ready) return "分区暂不可用";
            if (drive.free < RequiredSpace) return "空间不足，至少需要 12 GiB";
            return null;
        }
        public static string[] SystemCandidates(string local = null, string profile = null) {
            local = local ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            profile = profile ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string id = WindowsIdentity.GetCurrent().User.Value;
            return new[] { Path.Combine(local, "易容 Studio"), Path.Combine(local, "Apps", "易容 Studio"),
                Path.Combine(profile, "Apps", "易容 Studio"), Path.Combine(profile, "易容 Studio"),
                Path.Combine(@"C:\易容 Studio", id) };
        }
        public static string RootOnDrive(InstallDrive drive, IEnumerable<InstallDrive> all, bool probeWrites = true) {
            string problem = DriveProblem(drive, all); if (problem != null) throw new IOException(problem);
            return SelectAutomaticRoot(new[] { drive }, SystemCandidates(), probeWrites ? (Func<string, bool>)ProbeWritable : folder => true);
        }
        public static string SelectAutomaticRoot(IEnumerable<InstallDrive> drives, string onlyCFolder, Func<string, bool> writable) {
            return SelectAutomaticRoot(drives, new[] { onlyCFolder }, writable);
        }
        public static string SelectAutomaticRoot(IEnumerable<InstallDrive> drives, IEnumerable<string> cFolders, Func<string, bool> writable) {
            var list = drives.ToArray();
            foreach (var drive in list.Where(d => !String.Equals(Path.GetPathRoot(d.root), @"C:\", StringComparison.OrdinalIgnoreCase) && d.ready && d.free >= RequiredSpace).OrderByDescending(d => d.free)) {
                string candidate = Path.Combine(drive.root, "Program Files", "易容 Studio");
                if (writable(candidate)) return Canonical(candidate);
            }
            var system = list.FirstOrDefault(d => String.Equals(Path.GetPathRoot(d.root), @"C:\", StringComparison.OrdinalIgnoreCase));
            if (system != null && system.ready && system.free >= RequiredSpace) {
                foreach (string candidate in cFolders.Where(p => !String.IsNullOrWhiteSpace(p)).Distinct(StringComparer.OrdinalIgnoreCase)) {
                    if (String.Equals(Path.GetPathRoot(candidate), @"C:\", StringComparison.OrdinalIgnoreCase) && writable(candidate)) return Canonical(candidate);
                }
                throw new IOException("未找到可写的安装位置。\n已尝试 C 盘多个当前用户专用目录；请选择允许创建和替换 EXE 的专用文件夹，或检查安全软件的拦截记录，无需提升管理员权限。");
            }
            throw new IOException("没有可用的安装分区。\n需要至少 12 GiB 可用空间以及程序文件读写权限；请释放空间或选择可写目录后重新检测。");
        }
        public static InstallDrive[] SurveyDrives() {
            var drives = new List<InstallDrive>();
            foreach (var drive in DriveInfo.GetDrives()) try {
                if (drive.DriveType != DriveType.Fixed) continue;
                var item = new InstallDrive { root = drive.Name };
                try { item.ready = drive.IsReady; if (item.ready) item.free = drive.AvailableFreeSpace; } catch (IOException) { } catch (UnauthorizedAccessException) { }
                drives.Add(item);
            } catch (IOException) { }
            return drives.ToArray();
        }
        public static bool ProbeWritable(string root) {
            bool created = false; string probe = null, renamed = null;
            try {
                ValidateRoot(root);
                if (Directory.Exists(root) && !File.Exists(Path.Combine(root, Marker)) && Directory.EnumerateFileSystemEntries(root).Any()) return false;
                created = !Directory.Exists(root); Directory.CreateDirectory(root);
                string uninstaller = Path.Combine(root, "uninstall.exe");
                if (File.Exists(uninstaller)) using (new FileStream(uninstaller, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                probe = Path.Combine(root, ".faceswap-permission-test-" + Guid.NewGuid().ToString("N") + ".exe");
                renamed = probe + ".renamed.exe";
                File.Copy(Assembly.GetExecutingAssembly().Location, probe);
                using (var stream = new FileStream(probe, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { if (stream.Length == 0) return false; }
                File.Move(probe, renamed); File.Delete(renamed);
                return true;
            } catch (IOException) { return false; } catch (UnauthorizedAccessException) { return false; }
            finally {
                try {
                    if (probe != null && File.Exists(probe)) File.Delete(probe);
                    if (renamed != null && File.Exists(renamed)) File.Delete(renamed);
                    if (created && Directory.Exists(root) && !Directory.EnumerateFileSystemEntries(root).Any()) Directory.Delete(root);
                } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
        public static void InstallUninstaller(string root, string source = null) {
            ReadState(root);
            source = source ?? Assembly.GetExecutingAssembly().Location;
            string target = Path.Combine(root, "uninstall.exe");
            if (SamePath(source, target)) return;
            if (File.Exists(target)) using (var hash = SHA256.Create()) {
                byte[] first, second;
                using (var input = File.OpenRead(source)) first = hash.ComputeHash(input);
                using (var input = File.OpenRead(target)) second = hash.ComputeHash(input);
                if (first.SequenceEqual(second)) return;
            }
            string temp = Path.Combine(root, ".uninstall-" + Guid.NewGuid().ToString("N") + ".exe");
            try {
                File.Copy(source, temp);
                for (int attempt = 0; ; attempt++) {
                    try { Core.ReplaceFile(temp, target); break; }
                    catch (IOException) { if (attempt == 2) throw; Thread.Sleep(200 * (attempt + 1)); }
                    catch (UnauthorizedAccessException) { if (attempt == 2) throw; Thread.Sleep(200 * (attempt + 1)); }
                }
            } catch (Exception error) {
                if (!(error is IOException) && !(error is UnauthorizedAccessException)) throw;
                throw new IOException("无法写入卸载程序。请关闭正在运行的卸载器，或重新检测以选择可写安装目录；如被安全软件拦截，请查看拦截记录。\n" + target, error);
            } finally { try { if (File.Exists(temp)) File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
        }
        public static string DefaultRoot(bool probeWrites = true) {
            InstallState saved = null;
            using (var key = Registry.CurrentUser.OpenSubKey(SettingsKey)) {
                string value = key == null ? null : key.GetValue("InstallLocation") as string;
                if (!String.IsNullOrWhiteSpace(value)) try { saved = ReadState(value); } catch { }
            }
            if (saved != null && saved.state != "uninstalled") {
                if (!probeWrites || ProbeWritable(saved.root)) return Canonical(saved.root);
                if (saved.state == "complete") throw new IOException("现有安装目录不可写或卸载器被占用。\n请先关闭卸载器或检查安全软件限制，原有作品和模型已保留，不会自动迁移已完成的安装。");
            }
            return SelectAutomaticRoot(SurveyDrives(), SystemCandidates(), probeWrites ? (Func<string, bool>)ProbeWritable : folder => true);
        }
        public static void ValidateDestinationCapacity(string root, IEnumerable<InstallDrive> surveyed = null) {
            ValidateRoot(root); root = Canonical(root);
            // 已由本安装器接管的目录继续原地恢复，避免下载后剩余空间下降造成无法续装。
            if (File.Exists(Path.Combine(root, Marker)) && ReadState(root).state != "uninstalled") return;
            var drives = (surveyed ?? SurveyDrives()).ToArray();
            var drive = drives.FirstOrDefault(d => String.Equals(d.root, Path.GetPathRoot(root), StringComparison.OrdinalIgnoreCase));
            if (drive == null || !drive.ready || drive.free < RequiredSpace) throw new IOException("所选分区可用空间不足 12 GiB，或暂不可用。请调整安装位置或释放空间后重新检测。");
        }
        public static void ValidateRoot(string root) {
            root = Canonical(root);
            var forbidden = new[] { Path.GetPathRoot(root), Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Path.GetTempPath() };
            if (root.Length < 5 || forbidden.Where(p => !String.IsNullOrEmpty(p)).Any(p => SamePath(root, p))) throw new IOException("请选择专门的 易容 Studio 文件夹，不能直接安装到磁盘根目录或系统/个人资料目录。");
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            if (root.StartsWith(Canonical(windows) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("不能安装到 Windows 系统目录。");
            for (var dir = new DirectoryInfo(root); dir != null; dir = dir.Parent)
                if (dir.Exists && (dir.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("安装目录不能通过符号链接或目录连接，避免安装和卸载影响其他位置。");
        }
        public static InstallState ReadState(string root) {
            ValidateRoot(root);
            var state = Json.Deserialize<InstallState>(File.ReadAllText(Path.Combine(root, Marker)));
            Guid id;
            if (state == null || state.product != "faceswap-studio" || !Guid.TryParseExact(state.id, "N", out id) || !SamePath(root, state.root)) throw new IOException("安装归属记录无效，已拒绝修改此目录。");
            return state;
        }
        public static void SaveState(InstallState state) {
            string file = Path.Combine(state.root, Marker), part = file + ".tmp";
            File.WriteAllText(part, Json.Serialize(state), System.Text.Encoding.UTF8); Core.ReplaceFile(part, file);
        }
        public static FileStream AcquireRoot(string root) {
            ValidateRoot(root); root = Canonical(root);
            string lockPath = Path.Combine(root, ".faceswap-setup.lock");
            if (Directory.Exists(root) && !File.Exists(Path.Combine(root, Marker))) {
                var entries = Directory.GetFileSystemEntries(root);
                if (entries.Any(p => !SamePath(p, lockPath)) || (File.Exists(lockPath) && File.ReadAllText(lockPath) != "faceswap-studio")) throw new IOException("该目录已有其他内容，请选择新的专用文件夹。");
            }
            Directory.CreateDirectory(root);
            var lease = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            byte[] tag = System.Text.Encoding.ASCII.GetBytes("faceswap-studio"); lease.SetLength(0); lease.Write(tag, 0, tag.Length); lease.Flush(true); return lease;
        }
        public static InstallState Begin(string root, Manifest manifest, bool remember = true, string registryKey = UninstallKey, bool lockHeld = false) {
            ValidateRegistry(registryKey);
            ValidateRoot(root); root = Canonical(root);
            InstallState state = null;
            if (Directory.Exists(root)) {
                if (File.Exists(Path.Combine(root, Marker))) state = ReadState(root);
                else if (Directory.EnumerateFileSystemEntries(root).Any(p => !lockHeld || Path.GetFileName(p) != ".faceswap-setup.lock")) throw new IOException("该文件夹已有其他内容，请选择新的专用文件夹；已有便携版请保留原目录。");
            }
            using (var key = Registry.CurrentUser.OpenSubKey(registryKey)) {
                string installed = key == null ? null : key.GetValue("InstallLocation") as string;
                if (!String.IsNullOrEmpty(installed) && !SamePath(installed, root) && File.Exists(Path.Combine(installed, Marker))) throw new IOException("已在其他目录安装。请使用现有位置，或先从 Windows 应用列表卸载后再更换位置。");
            }
            Directory.CreateDirectory(root);
            string probe = Path.Combine(root, ".write-test-" + Guid.NewGuid().ToString("N"));
            using (File.Create(probe)) { } File.Delete(probe);
            if (state == null) state = new InstallState { root = root, id = Guid.NewGuid().ToString("N") };
            else if (state.state == "uninstalled") state.id = Guid.NewGuid().ToString("N");
            state.state = "preparing"; state.version = manifest.appVersion; state.releaseId = manifest.appReleaseId ?? manifest.releaseId;
            state.files = manifest.files.Select(a => a.name).Concat(new[] { "uninstall.exe", "faceswap.ico", "faceswap-installer.ico" }).Distinct().ToArray();
            SaveState(state);
            if (remember) using (var key = Registry.CurrentUser.CreateSubKey(SettingsKey)) key.SetValue("InstallLocation", root);
            return state;
        }
        public static void ExtractResource(string resource, string target) {
            using (var input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource)) {
                if (input == null) throw new IOException("安装资源缺失：" + resource);
                using (var output = File.Create(target)) input.CopyTo(output);
            }
        }
        static object Shell() { return Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true)); }
        public static string ShortcutTarget(string file) {
            object shell = null, link = null;
            try {
                shell = Shell(); link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { file });
                return Convert.ToString(link.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, link, null));
            } catch { return ""; }
            finally { if (link != null) Marshal.FinalReleaseComObject(link); if (shell != null) Marshal.FinalReleaseComObject(shell); }
        }
        static string CreateShortcut(string directory, string target, string root, string title, string arguments, string icon) {
            Directory.CreateDirectory(directory); string file = Path.Combine(directory, title + ".lnk");
            for (int i = 2; File.Exists(file) && !String.Equals(ShortcutTarget(file), target, StringComparison.OrdinalIgnoreCase); i++) {
                if (i > 50) throw new IOException("快捷方式名称被占用，请清理同名快捷方式。"); file = Path.Combine(directory, title + " (" + i + ").lnk");
            }
            object shell = null, link = null;
            try {
                shell = Shell(); link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { file });
                foreach (var pair in new[] { new[] { "TargetPath", target }, new[] { "Arguments", arguments }, new[] { "WorkingDirectory", root }, new[] { "IconLocation", icon }, new[] { "Description", title } })
                    link.GetType().InvokeMember(pair[0], BindingFlags.SetProperty, null, link, new object[] { pair[1] });
                link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
            } finally { if (link != null) Marshal.FinalReleaseComObject(link); if (shell != null) Marshal.FinalReleaseComObject(shell); }
            return file;
        }
        static void ValidateRegistry(string key) {
            if (key != UninstallKey && !System.Text.RegularExpressions.Regex.IsMatch(key ?? "", "^" + System.Text.RegularExpressions.Regex.Escape(UninstallKey) + @"\.Test\.[a-f0-9]{32}$")) throw new IOException("卸载注册路径无效。");
        }
        public static void Complete(string root, Manifest manifest, bool desktop, bool startMenu, IntegrationPaths paths = null, string readyReport = null, string session = null) {
            paths = paths ?? new IntegrationPaths(); ValidateRegistry(paths.registryKey);
            RequireReady(root, readyReport, session, manifest.componentProtocol >= 2);
            var state = ReadState(root);
            if (!File.Exists(Path.Combine(root, manifest.entry)) || !File.Exists(Path.Combine(root, "uninstall.exe"))) throw new IOException("应用或卸载器缺失，不能登记安装完成。");
            var shortcuts = new List<string>(state.shortcuts ?? new string[0]);
            Action<string, string, string, string> add = (dir, target, title, args) => {
                string link = CreateShortcut(dir, target, root, title, args, Path.Combine(root, "faceswap.ico"));
                if (!shortcuts.Contains(link)) shortcuts.Add(link); state.shortcuts = shortcuts.ToArray(); SaveState(state);
            };
            if (desktop) add(paths.desktop, Path.Combine(root, manifest.entry), "易容 Studio", "--faceswap-run");
            if (startMenu) {
                add(paths.startMenu, Path.Combine(root, manifest.entry), "易容 Studio", "--faceswap-run");
                add(paths.startMenu, Path.Combine(root, "uninstall.exe"), "卸载 易容 Studio", "--uninstall");
            }
            using (var key = Registry.CurrentUser.CreateSubKey(paths.registryKey)) {
                key.SetValue("DisplayName", "易容 Studio"); key.SetValue("DisplayVersion", manifest.appVersion ?? "2.0.2");
                key.SetValue("Publisher", "易容 Studio"); key.SetValue("InstallLocation", Canonical(root)); key.SetValue("InstallId", state.id);
                key.SetValue("DisplayIcon", Path.Combine(root, "faceswap.ico")); key.SetValue("UninstallString", "\"" + Path.Combine(root, "uninstall.exe") + "\" --uninstall");
                key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd")); key.SetValue("NoModify", 1, RegistryValueKind.DWord); key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
            state.registryKey = paths.registryKey; state.state = "complete"; SaveState(state);
        }
        // 修复旧安装后迁移已登记的系统入口；仅处理本安装拥有的快捷方式和注册项。
        public static void RefreshBrand(string root) {
            var state = ReadState(root);
            string launcher = Path.Combine(root, "易容 Studio.exe");
            if (!File.Exists(launcher)) return;
            var links = new List<string>();
            foreach (string shortcut in state.shortcuts ?? new string[0]) {
                if (!File.Exists(shortcut)) continue;
                string target = ShortcutTarget(shortcut);
                bool app = !String.IsNullOrEmpty(target) && (SamePath(target, launcher) || SamePath(target, Path.Combine(root, "启动FaceSwap Studio.exe")));
                bool uninstall = !String.IsNullOrEmpty(target) && SamePath(target, Path.Combine(root, "uninstall.exe"));
                if (!app && !uninstall) { links.Add(shortcut); continue; }
                string title = uninstall ? "卸载 易容 Studio" : "易容 Studio";
                if (Path.GetFileNameWithoutExtension(shortcut) == title && SamePath(target, app ? launcher : Path.Combine(root, "uninstall.exe"))) { links.Add(shortcut); continue; }
                string directory = Path.GetDirectoryName(shortcut);
                string oldMenu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "FaceSwap Studio");
                if (SamePath(directory, oldMenu)) directory = Path.Combine(Path.GetDirectoryName(oldMenu), "易容 Studio");
                string replacement = CreateShortcut(directory, app ? launcher : Path.Combine(root, "uninstall.exe"), root, title,
                    app ? "--faceswap-run" : "--uninstall", Path.Combine(root, "faceswap.ico"));
                links.Add(replacement);
                if (!SamePath(shortcut, replacement)) File.Delete(shortcut);
                if (SamePath(Path.GetDirectoryName(shortcut), oldMenu) && Directory.Exists(oldMenu) && !Directory.EnumerateFileSystemEntries(oldMenu).Any()) Directory.Delete(oldMenu);
            }
            state.shortcuts = links.ToArray(); SaveState(state);
            ValidateRegistry(state.registryKey ?? UninstallKey);
            using (var key = Registry.CurrentUser.OpenSubKey(state.registryKey ?? UninstallKey, true)) {
                if (key != null && Convert.ToString(key.GetValue("InstallId")) == state.id && SamePath(Convert.ToString(key.GetValue("InstallLocation")), root)) {
                    key.SetValue("DisplayName", "易容 Studio"); key.SetValue("Publisher", "易容 Studio");
                    key.SetValue("DisplayVersion",state.version);
                }
            }
        }
        static void ValidateReportPath(string root, string report, string session) {
            Guid parsed;
            if (String.IsNullOrEmpty(report) || !Guid.TryParseExact(session, "N", out parsed) ||
                !SamePath(Path.GetDirectoryName(report), Path.Combine(Canonical(root), "data", "cache", "install")) || Path.GetFileNameWithoutExtension(report) != session || Path.GetExtension(report) != ".json")
                throw new IOException("安装握手路径无效。");
        }
        public static void RequireReady(string root, string report, string session, bool requireComponents = false) {
            ValidateReportPath(root, report, session);
            if (!File.Exists(report)) throw new IOException("运行环境尚未完成，不能登记安装完成。");
            var result = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(report));
            if (Convert.ToString(result["session"]) != session || !SamePath(Convert.ToString(result["root"]), root)) throw new IOException("安装就绪报告与当前会话不一致。");
            if (!Convert.ToBoolean(result["ok"])) throw new IOException(Convert.ToString(result["error"]));
            if (Convert.ToString(result["status"]) != "ready") throw new IOException("本地服务尚未就绪。");
            if (requireComponents) {
                object raw;
                if (!result.TryGetValue("components", out raw)) throw new IOException("缺少所选组件就绪报告。");
                var receipt = raw as Dictionary<string, object>;
                if (receipt == null || Convert.ToInt32(receipt["protocol"]) != 2 || !System.Text.RegularExpressions.Regex.IsMatch(Convert.ToString(receipt["signature"]), "^[a-f0-9]{64}$")) throw new IOException("组件就绪报告无效。");
                var selected = ((System.Collections.IEnumerable)receipt["selected"]).Cast<object>().Select(Convert.ToString).OrderBy(x => x).ToArray();
                var profile = Json.Deserialize<ComponentSelection>(File.ReadAllText(Path.Combine(root, "data", "component-selection.json")));
                if (!selected.SequenceEqual(profile.selected.OrderBy(x => x))) throw new IOException("组件报告与安装选择不一致。");
                var stored = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(root, "data", "cache", "component-ready.json")));
                if (Convert.ToString(stored["signature"]) != Convert.ToString(receipt["signature"])) throw new IOException("组件自检记录不匹配。");
            }
        }
        public static async Task WaitForReady(string root, string report, string session, Process child, CancellationToken token, IProgress<Status> progress, bool requireComponents = false) {
            ValidateReportPath(root, report, session);
            var deadline = DateTime.UtcNow.AddHours(24); string previous = "";
            while (DateTime.UtcNow < deadline) {
                token.ThrowIfCancellationRequested();
                if (File.Exists(report)) {
                    RequireReady(root, report, session, requireComponents);
                    return;
                }
                string progressPath = report + ".progress";
                if (File.Exists(progressPath)) try {
                    string text = File.ReadAllText(progressPath);
                    if (text != previous) {
                        var value = Json.Deserialize<Dictionary<string, object>>(text);
                        if (Convert.ToString(value["session"]) == session) {
                            object name, done, size; value.TryGetValue("name", out name); value.TryGetValue("downloaded", out done); value.TryGetValue("size", out size);
                            progress.Report(new Status { text = Convert.ToString(value["message"]), done = done == null ? 0 : Convert.ToInt64(done), total = size == null ? 0 : Convert.ToInt64(size) });
                            previous = text;
                        }
                    }
                } catch (IOException) { }
                if (child != null && child.HasExited) throw new IOException("工作台准备进程已退出。若已有工作台正在运行，请关闭后重试安装。");
                await Task.Delay(300, token);
            }
            throw new IOException("环境准备超时，已保留下载内容，请重新打开安装器继续。");
        }
        public static Process StartPreparation(string root, string report, string session) {
            var start = new ProcessStartInfo(Path.Combine(root, ".python", "python.exe"), "\"" + Path.Combine(root, "scripts", "bootstrap_prepare.py") + "\"") { WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true };
            start.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
            foreach (string name in new[] { "FACESWAP_STUDIO_APP_ROOT", "FACESWAP_STUDIO_PYTHON_EXE", "FACESWAP_STUDIO_MODEL_DIR" }) start.EnvironmentVariables.Remove(name);
            start.EnvironmentVariables["FACESWAP_STUDIO_DATA_ROOT"] = Path.Combine(root, "data");
            start.EnvironmentVariables["FACESWAP_STUDIO_INSTALL_REPORT"] = report; start.EnvironmentVariables["FACESWAP_STUDIO_INSTALL_SESSION"] = session;
            return Process.Start(start);
        }
        public static void StopChild(Process child) {
            if (child == null || child.HasExited) return;
            using (var killer = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + child.Id + " /T /F") { UseShellExecute = false, CreateNoWindow = true })) killer.WaitForExit(15000);
        }
        public static void DeleteOwnedTree(string path) {
            if (!Directory.Exists(path)) { if (File.Exists(path)) File.Delete(path); return; }
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) { Directory.Delete(path); return; }
            foreach (string item in Directory.EnumerateFileSystemEntries(path)) {
                var attributes = File.GetAttributes(item);
                if ((attributes & FileAttributes.Directory) != 0) DeleteOwnedTree(item);
                else { File.SetAttributes(item, FileAttributes.Normal); File.Delete(item); }
            }
            Directory.Delete(path);
        }
        static void RemoveOwnedPath(string root, string relative) {
            string target = Core.SafePath(root, relative), cursor = Path.GetDirectoryName(target);
            while (!SamePath(cursor, root)) {
                if (Directory.Exists(cursor) && (File.GetAttributes(cursor) & FileAttributes.ReparsePoint) != 0) return;
                cursor = Path.GetDirectoryName(cursor);
            }
            DeleteOwnedTree(target);
        }
        public static void Remove(string root, string id, bool removePersonalData) {
            ReadState(root);
            using (var lease = AcquireRoot(root)) {
                var state = ReadState(root); if (state.id != id) throw new IOException("卸载会话归属不匹配。");
                ValidateRegistry(state.registryKey ?? UninstallKey);
                // 文件清理成功后才移除快捷方式和应用登记，失败时保留可重试的卸载入口。
                foreach (string name in new[] { "facefusion", "updater", ".python", ".venv-win", ".runtime", ".assets", "installer", "scripts" }) DeleteOwnedTree(Core.SafePath(root, name));
                foreach (string name in state.files ?? new string[0]) {
                    if (name.Contains("/") || name.Contains("\\") || name == Marker || name == "uninstall.exe" || name == "faceswap.ico" || name == "faceswap-installer.ico") continue;
                    string file = Core.SafePath(root, name); if (File.Exists(file)) { File.SetAttributes(file, FileAttributes.Normal); File.Delete(file); }
                }
                RemoveOwnedPath(root, "faceswap studio/bridge");
                RemoveOwnedPath(root, "faceswap studio/runtime");
                RemoveOwnedPath(root, "faceswap studio/flutter_app");
                if (removePersonalData) RemoveOwnedPath(root, "faceswap studio/data");
                if (removePersonalData) RemoveOwnedPath(root, "faceswap studio/config");
                else RemoveOwnedPath(root, "faceswap studio/data/cache");
                string data = Core.SafePath(root, "data");
                if (removePersonalData) DeleteOwnedTree(data);
                else if (Directory.Exists(data) && (File.GetAttributes(data) & FileAttributes.ReparsePoint) == 0) DeleteOwnedTree(Core.SafePath(root, "data/cache"));
                foreach (string shortcut in state.shortcuts ?? new string[0]) {
                    if (Path.GetExtension(shortcut).Equals(".lnk", StringComparison.OrdinalIgnoreCase) && File.Exists(shortcut)) {
                        string target = ShortcutTarget(shortcut);
                        if (!String.IsNullOrEmpty(target) && (SamePath(target, Path.Combine(root, "易容 Studio.exe")) || SamePath(target, Path.Combine(root, "启动FaceSwap Studio.exe")) || SamePath(target, Path.Combine(root, "uninstall.exe")))) File.Delete(shortcut);
                    }
                }
                using (var key = Registry.CurrentUser.OpenSubKey(state.registryKey ?? UninstallKey)) {
                    if (key != null && Convert.ToString(key.GetValue("InstallId")) == id && SamePath(Convert.ToString(key.GetValue("InstallLocation")), root)) {
                        key.Close(); Registry.CurrentUser.DeleteSubKeyTree(state.registryKey ?? UninstallKey, false);
                    }
                }
                foreach (string name in new[] { "uninstall.exe", "faceswap.ico", "faceswap-installer.ico" }) {
                    string file = Path.Combine(root, name); if (File.Exists(file)) File.Delete(file);
                }
                state.state = "uninstalled"; state.shortcuts = new string[0]; SaveState(state);
                try { using (var key = Registry.CurrentUser.OpenSubKey(SettingsKey, true)) if (key != null && SamePath(Convert.ToString(key.GetValue("InstallLocation", root)), root)) key.DeleteValue("InstallLocation", false); } catch (ArgumentException) { }
            }
        }
        public static bool RouteUninstall(string[] args) {
            int index = Array.IndexOf(args, "--uninstall-root");
            bool entry = args.Contains("--uninstall") || Path.GetFileName(Assembly.GetExecutingAssembly().Location).Equals("uninstall.exe", StringComparison.OrdinalIgnoreCase);
            if (index < 0 && !entry) return false;
            if (index < 0) {
                string root = AppDomain.CurrentDomain.BaseDirectory; var state = ReadState(root);
                string temp = Path.Combine(Path.GetTempPath(), "FaceSwap-Uninstall-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(temp);
                string executable = Path.Combine(temp, "uninstall.exe"); File.Copy(Assembly.GetExecutingAssembly().Location, executable);
                Process.Start(new ProcessStartInfo(executable, "--uninstall-root \"" + Canonical(root) + "\" --install-id " + state.id + " --wait-pid " + Process.GetCurrentProcess().Id) { UseShellExecute = false });
                return true;
            }
            if (index + 1 >= args.Length) throw new IOException("卸载目录参数缺失。");
            string targetRoot = args[index + 1]; var owned = ReadState(targetRoot);
            int identity = Array.IndexOf(args, "--install-id"); if (identity < 0 || identity + 1 >= args.Length || owned.id != args[identity + 1]) throw new IOException("卸载安装标识不匹配。");
            int parent = Array.IndexOf(args, "--wait-pid");
            if (parent >= 0 && parent + 1 < args.Length) try { Process.GetProcessById(Int32.Parse(args[parent + 1])).WaitForExit(10000); } catch (ArgumentException) { }
            using (var dialog = new Form { Text = "卸载 易容 Studio", ClientSize = new System.Drawing.Size(500, 220), StartPosition = FormStartPosition.CenterScreen, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, BackColor = System.Drawing.Color.White, Font = new System.Drawing.Font("Microsoft YaHei UI", 10) }) {
                dialog.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
                var label = new Label { Text = "卸载应用、运行环境和下载的模型。\n默认保留配置、音色、作品与 LoRA。", Left = 26, Top = 24, Width = 450, Height = 60 };
                var personal = new CheckBox { Text = "同时删除个人数据（不可恢复）", Left = 26, Top = 96, Width = 440, AutoSize = true };
                var remove = new Button { Text = "卸载", Left = 360, Top = 160, Width = 110, Height = 34 };
                remove.Click += (sender, e) => {
                    try {
                        foreach (var process in Process.GetProcessesByName("易容 Studio")) try {
                            if (SamePath(process.MainModule.FileName, Path.Combine(targetRoot, "易容 Studio.exe"))) throw new IOException("请先关闭正在运行的工作台，再进行卸载。");
                        } catch (System.ComponentModel.Win32Exception) { } finally { process.Dispose(); }
                        Remove(targetRoot, owned.id, personal.Checked);
                        MessageBox.Show(dialog, personal.Checked ? "卸载完成。" : "卸载完成。个人数据保留在：\n" + Path.Combine(targetRoot, "faceswap studio", "data"), "易容 Studio"); dialog.Close();
                    } catch (Exception error) { MessageBox.Show(dialog, error.Message, "卸载尚未完成", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                };
                dialog.Controls.AddRange(new Control[] { label, personal, remove }); Application.Run(dialog);
            }
            ScheduleTempCleanup(); return true;
        }
        static void ScheduleTempCleanup() {
            string directory = Canonical(AppDomain.CurrentDomain.BaseDirectory);
            if (!SamePath(Path.GetDirectoryName(directory), Path.GetTempPath()) || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(directory), @"^FaceSwap-Uninstall-[a-f0-9]{32}$")) return;
            var start = new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -Command \"Wait-Process -Id $env:FACESWAP_STUDIO_REMOVE_PID -ErrorAction SilentlyContinue; $p=[IO.Path]::GetFullPath($env:FACESWAP_STUDIO_REMOVE_TEMP); if (([IO.Path]::GetDirectoryName($p) -eq [IO.Path]::GetTempPath().TrimEnd('\\')) -and ([IO.Path]::GetFileName($p) -match '^FaceSwap-Uninstall-[a-f0-9]{32}$')) {Remove-Item -LiteralPath $p -Recurse -Force}\"") { UseShellExecute = false, CreateNoWindow = true };
            start.EnvironmentVariables["FACESWAP_STUDIO_REMOVE_PID"] = Process.GetCurrentProcess().Id.ToString(); start.EnvironmentVariables["FACESWAP_STUDIO_REMOVE_TEMP"] = directory; Process.Start(start);
        }
    }
}
