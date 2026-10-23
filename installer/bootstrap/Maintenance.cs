using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Management;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace FaceSwapBootstrap {
    public sealed class MaintenanceInspection {
        public List<Asset> damaged = new List<Asset>();
        public List<string> issues = new List<string>();
        public bool runtimePath, pending;
        public bool Healthy { get { return issues.Count == 0; } }
    }
    public sealed class MaintenanceResult {
        public string status, message, root, session;
        public bool repaired;
        public string[] issues;
    }
    public sealed class RepairChange { public string name; public bool existed; }

    /// <summary>在原生安装器内执行，无需依赖损坏安装中的 Python 或更新模块。</summary>
    public static class Maintenance {
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
        public const string HealthyMessage = "一切正常，无需再次安装，开始创作吧。";
        static readonly string UpdateCache = "faceswap studio/data/cache/updates";
        public static bool IsInstalled(string root) {
            try { return !String.IsNullOrWhiteSpace(root) && Installer.ReadState(root).state == "complete"; }
            catch { return false; }
        }
        public static string FindInstallation() {
            foreach(string name in new[] { @"Software\FaceSwapStudio\Installer", Installer.UninstallKey })
                using(var key = Registry.CurrentUser.OpenSubKey(name)) {
                    string root = key == null ? null : key.GetValue("InstallLocation") as string;
                    if(IsInstalled(root)) return Installer.Canonical(root);
                }
            string adjacent = AppDomain.CurrentDomain.BaseDirectory;
            return IsInstalled(adjacent) ? Installer.Canonical(adjacent) : null;
        }
        public static string Safe(string root, string name) {
            string path = Core.SafePath(root, name);
            for(var directory = new DirectoryInfo(Path.GetDirectoryName(path)); directory != null; directory = directory.Parent) {
                if(directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("检查或修复路径不能经过目录连接：" + name);
                if(Installer.SamePath(directory.FullName, root)) break;
            }
            if(File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("检查或修复文件不能是符号链接：" + name);
            return path;
        }
        static Dictionary<string, object> Read(string file) {
            return Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(file));
        }
        static void Write(string file, object value) {
            Directory.CreateDirectory(Path.GetDirectoryName(file));
            string part = file + ".new";
            File.WriteAllText(part, Json.Serialize(value), new UTF8Encoding(false));
            Core.ReplaceFile(part, file);
        }
        public static void GuardVersion(string root, Manifest manifest) {
            var state = Installer.ReadState(root);
            Version installed, wanted;
            if(!Version.TryParse(manifest.appVersion, out wanted)) throw new IOException("安装器版本无效");
            string version = File.Exists(Safe(root,"VERSION")) ? File.ReadAllText(Safe(root,"VERSION")).Trim() : state.version;
            if(!Version.TryParse(version, out installed) && !Version.TryParse(state.version, out installed))
                throw new IOException("无法确认已安装版本，不能安全修复；请保留原目录并查看日志。");
            if(installed > wanted) throw new IOException("已安装版本高于此修复包，请使用更新的安装器；原文件未改动。");
            string release = state.releaseId;
            try {
                var config = Read(Safe(root,"update-config.json"));
                object value;
                if(config.TryGetValue("releaseId", out value) && System.Text.RegularExpressions.Regex.IsMatch(Convert.ToString(value),@"^[0-9]{14}$")) release = Convert.ToString(value);
            } catch { }
            if(!System.Text.RegularExpressions.Regex.IsMatch(release ?? "", @"^[0-9]{14}$"))
                throw new IOException("无法确认安装发布序号，不能安全修复；请使用对应版本安装器并保留原目录。");
            if(installed == wanted && String.CompareOrdinal(release, manifest.appReleaseId ?? manifest.releaseId) > 0)
                throw new IOException("已安装发布序号高于此修复包，已禁止降级；原文件未改动。");
        }
        static bool ConfigMatches(string root, Manifest manifest) {
            try {
                var config = Read(Safe(root,"update-config.json"));
                return Convert.ToString(config["releaseId"]) == (manifest.appReleaseId ?? manifest.releaseId)
                    && !String.IsNullOrEmpty(manifest.publicKey) && Convert.ToString(config["publicKey"]) == manifest.publicKey;
            } catch { return false; }
        }
        static bool RuntimePathMatches(string root) {
            try {
                string wanted = Installer.Canonical(Path.Combine(root,".python"));
                string line = File.ReadLines(Safe(root,".venv-win/pyvenv.cfg")).FirstOrDefault(s => s.TrimStart().StartsWith("home",StringComparison.OrdinalIgnoreCase));
                return line != null && line.Contains("=") && Installer.SamePath(line.Substring(line.IndexOf('=')+1).Trim(),wanted);
            } catch { return false; }
        }
        public static void ProbeRuntime(string root, CancellationToken token) {
            var info = new ProcessStartInfo(Safe(root,".venv-win/Scripts/python.exe"),
                "-I -B -c \"import sys,onnxruntime,cv2,fastapi,cryptography,uvicorn; assert sys.prefix != sys.base_prefix; print('runtime-ready')\"") {
                WorkingDirectory=root, UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true
            };
            info.EnvironmentVariables.Remove("PYTHONPATH"); info.EnvironmentVariables.Remove("PYTHONHOME");
            using(var process = Process.Start(info)) {
                var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
                var timer = Stopwatch.StartNew();
                while(!process.WaitForExit(200)) {
                    if(token.IsCancellationRequested || timer.Elapsed.TotalSeconds > 90) {
                        process.Kill(); process.WaitForExit(); token.ThrowIfCancellationRequested();
                        throw new IOException("运行环境自检超时");
                    }
                }
                if(process.ExitCode != 0 || !stdout.Result.Contains("runtime-ready"))
                    throw new IOException("运行环境加载失败：" + stderr.Result.Substring(Math.Max(0,stderr.Result.Length-800)));
            }
        }
        public static MaintenanceInspection Inspect(string root, Manifest manifest, CancellationToken token, IProgress<Status> progress, bool probe = true) {
            root = Installer.Canonical(root); Installer.ValidateRoot(root); Core.Validate(manifest); GuardVersion(root,manifest);
            var result = new MaintenanceInspection();
            long total = manifest.files.Sum(f => f.size), done = 0; var timer=Stopwatch.StartNew();
            foreach(var file in manifest.files) {
                token.ThrowIfCancellationRequested(); string path = Safe(root,file.name); bool valid;
                if(file.name == ".venv-win/pyvenv.cfg") { valid = RuntimePathMatches(root); result.runtimePath = !valid; }
                else if(file.name == "facefusion.ini") valid = File.Exists(path);
                else if(file.name == "update-config.json") valid = ConfigMatches(root,manifest);
                else valid = Core.Verified(path,file);
                if(!valid) { result.damaged.Add(file); result.issues.Add("文件缺失、损坏或版本不一致：" + file.name); }
                done += file.size;
                if(done == total || timer.ElapsedMilliseconds>=150) {
                    progress.Report(new Status { text="正在检查程序、依赖和模型：" + file.name,done=done,total=total }); timer.Restart();
                }
            }
            var icon=manifest.files.FirstOrDefault(f=>f.name=="facefusion.ico");
            if(icon!=null) foreach(var file in IntegrationFiles(icon)) {
                if(!Core.Verified(Safe(root,file.name),file)) { result.damaged.Add(file);result.issues.Add("安装集成文件缺失或需要更新："+file.name); }
            }
            foreach(string name in new[] { "pending.json" })
                if(File.Exists(Safe(root,UpdateCache+"/"+name))) { result.pending=true; result.issues.Add("存在未完成更新："+name); }
            if(result.Healthy && probe) {
                progress.Report(new Status { text="正在只读检查 Python 与推理依赖" });
                try { ProbeRuntime(root,token); } catch(OperationCanceledException) { throw; }
                catch(Exception error) { result.issues.Add(error.Message); }
            }
            return result;
        }
        static List<Process> OwnedProcesses(string root) {
            string prefix=Installer.Canonical(root)+Path.DirectorySeparatorChar;
            var parents=new Dictionary<int,int>(); var owned=new HashSet<int>(); int self=Process.GetCurrentProcess().Id;
            using(var search=new ManagementObjectSearcher("SELECT ProcessId,ParentProcessId,ExecutablePath FROM Win32_Process"))
                foreach(ManagementObject item in search.Get()) using(item) {
                    int pid=Convert.ToInt32(item["ProcessId"]); parents[pid]=Convert.ToInt32(item["ParentProcessId"]);
                    string exe=item["ExecutablePath"] as string;
                    if(pid!=self && exe!=null && exe.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)) owned.Add(pid);
                }
            bool added;
            do { added=false; foreach(var item in parents) if(item.Key!=self && owned.Contains(item.Value) && owned.Add(item.Key)) added=true; } while(added);
            var result=new List<Process>();
            foreach(int pid in owned) try { result.Add(Process.GetProcessById(pid)); } catch(ArgumentException) { }
            return result;
        }
        delegate bool WindowVisitor(IntPtr window, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumWindows(WindowVisitor callback, IntPtr data);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
        [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window,StringBuilder text,int count);
        [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window,StringBuilder text,int count);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
        internal static void CloseCompletedUpdaters(string root,List<Process> processes,CancellationToken token) {
            string cache=Safe(root,UpdateCache)+Path.DirectorySeparatorChar;
            foreach(var process in processes) {
                token.ThrowIfCancellationRequested();
                try {
                    if(process.HasExited) continue;
                    string exe=process.MainModule.FileName,session=Path.GetDirectoryName(exe);
                    if(!String.Equals(Path.GetFileName(exe),"FaceSwapStudioUpdater.exe",StringComparison.OrdinalIgnoreCase) ||
                        !session.StartsWith(cache,StringComparison.OrdinalIgnoreCase)) continue;
                    string status=Safe(session,"status.json"),identity=Safe(session,"session.json");
                    if(!File.Exists(status) || !File.Exists(identity)) continue;
                    var state=Read(status);var update=Read(identity);object value;
                    if(!state.TryGetValue("status",out value) || Convert.ToString(value)!="complete" ||
                        !update.TryGetValue("root",out value) || !Installer.SamePath(Convert.ToString(value),root)) continue;
                    // 只请求正常关闭；正在更新的窗口仍可拒绝关闭，不强杀任何进程。
                    bool requested=false;
                    WindowVisitor visit=(window,data)=> {
                        uint pid;GetWindowThreadProcessId(window,out pid);
                        if(pid==(uint)process.Id) {
                            var title=new StringBuilder(256);GetWindowText(window,title,256);
                            if(title.ToString()=="易容 Studio · 软件更新" || title.ToString()=="FaceSwap Studio · 软件更新")
                                requested=PostMessage(window,0x0010,IntPtr.Zero,IntPtr.Zero)||requested;
                        }
                        return true;
                    };
                    EnumWindows(visit,IntPtr.Zero);
                    if(requested) {
                        var timer=Stopwatch.StartNew();
                        while(!process.WaitForExit(100) && timer.Elapsed.TotalSeconds<5) token.ThrowIfCancellationRequested();
                    }
                } catch(System.ComponentModel.Win32Exception) { }
                catch(InvalidOperationException) { }
                catch(IOException) { }
                catch(ArgumentException) { }
            }
        }
        static void StopOwned(string root, CancellationToken token) {
            var processes=OwnedProcesses(root);
            if(processes.Count==0) return;
            try {
                CloseCompletedUpdaters(root,processes,token);
                if(processes.All(p=>p.HasExited)) return;
                try {
                    var request=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:52741/queue/tasks"); request.Timeout=3000;
                    using(var response=request.GetResponse()) using(var reader=new StreamReader(response.GetResponseStream())) {
                        var queue=Json.Deserialize<Dictionary<string,object>>(reader.ReadToEnd());
                        var runner=(Dictionary<string,object>)queue["runner"];
                        if(Convert.ToBoolean(runner["active"]) || ((System.Collections.IEnumerable)queue["tasks"]).Cast<object>().Any()) throw new IOException("生成队列仍有任务，请完成或取消任务后再修复。");
                    }
                } catch(WebException) { throw new IOException("工作台仍在运行但无法确认生成队列，请先从托盘退出本目录工作台，再重试修复。"); }
                var ids=new HashSet<int>(processes.Select(p=>p.Id));
                WindowVisitor visit=(window,data)=> {
                    uint pid; GetWindowThreadProcessId(window,out pid);
                    if(ids.Contains((int)pid)) {
                        var name=new StringBuilder(256); GetClassName(window,name,256);
                        if(name.ToString()=="FLUTTER_RUNNER_WIN32_WINDOW") PostMessage(window,0x0111,new IntPtr(1002),IntPtr.Zero);
                    }
                    return true;
                };
                EnumWindows(visit,IntPtr.Zero);
                var timer=Stopwatch.StartNew();
                while(timer.Elapsed.TotalSeconds<30 && processes.Any(p=>!p.HasExited)) { token.ThrowIfCancellationRequested(); Thread.Sleep(200); }
                // 不强杀未知生成进程；保留现有应用与数据，让用户正常退出后重试。
                if(processes.Any(p=>!p.HasExited)) throw new IOException("本目录进程尚未正常退出，未开始替换文件；请退出工作台后重试。");
            } finally { foreach(var process in processes) process.Dispose(); }
        }
        static string GetPackage(string root, Asset asset, string local, CancellationToken token,IProgress<Status> progress, bool offline = false) {
            if(!String.IsNullOrEmpty(local)) {
                if(!Core.Verified(local,asset)) throw new IOException("本地运行包校验失败");
                return Path.GetFullPath(local);
            }
            string adjacent=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,asset.name);
            if(Core.Verified(adjacent,asset)) return adjacent;
            string cache=Safe(root,"data/cache/bootstrap/"+asset.name);
            return Core.PackagePath(asset,Path.GetDirectoryName(cache),offline,token,progress);
        }
        static Asset[] IntegrationFiles(Asset icon) {
            string self=Assembly.GetExecutingAssembly().Location;
            return new[] {
                new Asset{name="faceswap.ico",size=icon.size,sha256=icon.sha256},
                new Asset{name="faceswap-installer.ico",size=icon.size,sha256=icon.sha256},
                new Asset{name="uninstall.exe",size=new FileInfo(self).Length,sha256=Core.Hash(self)}
            };
        }
        static void Stage(string package,string stage,IEnumerable<Asset> files,CancellationToken token,Manifest application=null) {
            using(var zip=ZipFile.OpenRead(package)) foreach(var file in files) {
                token.ThrowIfCancellationRequested();
                string target=Safe(stage,file.name); Directory.CreateDirectory(Path.GetDirectoryName(target));
                if(file.name=="uninstall.exe") { File.Copy(Assembly.GetExecutingAssembly().Location,target); continue; }
                string sourceName=(file.name=="faceswap.ico" || file.name=="faceswap-installer.ico")?"facefusion.ico":file.name;
                string name=application==null?"FaceSwapStudio/"+sourceName:Core.ApplicationSource(application,sourceName);
                var entries=zip.Entries.Where(e=>e.FullName==name).ToArray();
                if(entries.Length!=1 || entries[0].Length!=file.size || ((entries[0].ExternalAttributes>>16)&0xf000)==0xa000)
                    throw new IOException("修复包条目无效："+file.name);
                using(var input=entries[0].Open()) using(var output=File.Create(target)) input.CopyTo(output);
                if(!Core.Verified(target,file)) throw new IOException("修复文件校验失败："+file.name);
            }
        }
        static void RuntimeConfig(string root,string target) {
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            File.WriteAllText(target,"home = "+Path.Combine(root,".python")+"\ninclude-system-site-packages = false\nexecutable = "+Path.Combine(root,".python/python.exe")+"\n",new UTF8Encoding(false));
        }
        public static void Rollback(string root,string work,IEnumerable<RepairChange> changes) {
            foreach(var change in changes.Reverse()) {
                string target=Safe(root,change.name);
                if(change.existed) {
                    string backup=Safe(Path.Combine(work,"backup"),change.name);
                    if(!File.Exists(backup)) throw new IOException("修复回滚备份缺失："+change.name);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    string temp=target+".repair-restore"; File.Copy(backup,temp,true); Core.ReplaceFile(temp,target);
                } else if(File.Exists(target)) File.Delete(target);
            }
        }
        static List<Asset> PendingFiles(string root, Manifest manifest) {
            var selected=new List<Asset>();
            foreach(string marker in new[]{"pending.json"}) {
                string path=Safe(root,UpdateCache+"/"+marker);
                if(!File.Exists(path)) continue;
                var pending=Read(path); string session=Path.GetFullPath(Convert.ToString(pending["session"]));
                string prefix=Path.GetFullPath(Path.Combine(root,UpdateCache))+Path.DirectorySeparatorChar;
                if(!session.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)) throw new IOException("未完成更新不属于此安装目录");
                // 确认会话归属；不执行损坏安装里的事务脚本，按可信完整包前向恢复。
                string relative=session.Substring(Installer.Canonical(root).Length+1).Replace('\\','/');
                Safe(root,relative+"/session.json");
                var settings=Read(Path.Combine(session,"session.json"));
                if(!Installer.SamePath(Convert.ToString(settings["root"]),root)) throw new IOException("更新事务目标目录不一致");
                string journal=Path.Combine(session,"journal.json");
                if(File.Exists(journal)) {
                    var state=Read(journal); object raw;
                    if(state.TryGetValue("changes",out raw)) foreach(var value in (System.Collections.IEnumerable)raw) {
                        string name=Convert.ToString(((Dictionary<string,object>)value)["path"]);
                        var file=manifest.files.FirstOrDefault(f=>f.name==name);
                        if(file==null) throw new IOException("旧事务含不属于可信运行包的文件，已保留日志："+name);
                        selected.Add(file);
                    }
                }
            }
            return selected;
        }
        public static MaintenanceResult Run(string root,Manifest manifest,bool repair,CancellationToken token,IProgress<Status> progress,
            string localPackage=null,string work=null,bool probe=true,int failAfter=-1) {
            root=Installer.Canonical(root);
            work=Path.GetFullPath(work??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"FaceSwapStudioMaintenance","sessions",Guid.NewGuid().ToString("N")));
            if(work.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase) || Installer.SamePath(work,root))
                throw new IOException("修复日志与备份必须独立于待修复安装目录");
            try { return RunCore(root,manifest,repair,token,progress,localPackage,work,probe,failAfter); }
            catch(Exception error) {
                Write(Path.Combine(work,"error.json"),new {status="error",message=error.ToString(),root});
                if(error is OperationCanceledException) throw;
                throw new IOException(error.Message+"\n检查日志："+work,error);
            }
        }
        static MaintenanceResult RunCore(string root,Manifest manifest,bool repair,CancellationToken token,IProgress<Status> progress,
            string localPackage,string work,bool probe,int failAfter) {
            root=Installer.Canonical(root);
            var before=Inspect(root,manifest,token,progress,probe);
            if(before.Healthy) return new MaintenanceResult {status="healthy",message=HealthyMessage,root=root,repaired=false,issues=new string[0]};
            if(!repair) return new MaintenanceResult {status="damaged",message="发现 "+before.issues.Count+" 项问题；修复将正常关闭本目录工作台并保留个人数据。",root=root,repaired=false,issues=before.issues.ToArray()};
            work=work??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"FaceSwapStudioMaintenance","sessions",Guid.NewGuid().ToString("N"));
            work=Path.GetFullPath(work);
            if(work.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)) throw new IOException("修复日志与备份必须独立于待修复安装目录");
            Directory.CreateDirectory(work); Write(Path.Combine(work,"inspection.json"),before.issues);
            using(var lease=Installer.AcquireRoot(root)) {
                GuardVersion(root,manifest);
                var selected=before.damaged.Concat(PendingFiles(root,manifest)).GroupBy(f=>f.name).Select(g=>g.First()).ToList();
                if(selected.Count==0 && !before.pending) {
                    // 导入失败但字节清单正常时不能盲目覆盖，保留真实诊断。
                    throw new IOException("程序文件完整，但运行环境探测失败；请查看检查报告。未覆盖任何文件。");
                }
                var appNames=new HashSet<string>(manifest.applicationFiles??new string[0],StringComparer.OrdinalIgnoreCase);
                Func<Asset,bool> fromApplication=f=>manifest.application!=null && appNames.Contains(f.name=="faceswap.ico" || f.name=="faceswap-installer.ico"?"facefusion.ico":f.name);
                var baseSelected=selected.Where(f=>f.name!="uninstall.exe" && !fromApplication(f)).ToList();
                var appSelected=selected.Where(f=>fromApplication(f)).ToList();
                string package=baseSelected.Count==0?null:GetPackage(root,manifest.package,localPackage,token,progress,manifest.offline);
                string applicationPackage=appSelected.Count==0?null:GetPackage(root,manifest.application,null,token,progress);
                if(new DriveInfo(Path.GetPathRoot(work)).AvailableFreeSpace < selected.Sum(f=>f.size)*2+32L*1024*1024)
                    throw new IOException("修复会话所在磁盘空间不足，未开始替换文件。");
                string stage=Path.Combine(work,"stage"); Directory.CreateDirectory(stage);
                if(package!=null) Stage(package,stage,baseSelected,token);
                if(applicationPackage!=null) Stage(applicationPackage,stage,appSelected,token,manifest);
                if(selected.Any(f=>f.name=="uninstall.exe")) File.Copy(Assembly.GetExecutingAssembly().Location,Safe(stage,"uninstall.exe"));
                if(selected.Any(f=>f.name==".venv-win/pyvenv.cfg")) RuntimeConfig(root,Safe(stage,".venv-win/pyvenv.cfg"));
                if(selected.Any(f=>f.name=="update-config.json")) {
                    try {
                        var existing=Read(Safe(root,"update-config.json")); var replacement=Read(Safe(stage,"update-config.json"));
                        object flag; if(existing.TryGetValue("autoCheck",out flag) && flag is bool) replacement["autoCheck"]=flag;
                        Write(Safe(stage,"update-config.json"),replacement);
                    } catch(IOException) { } catch(ArgumentException) { } catch(InvalidOperationException) { }
                }
                if(new DriveInfo(Path.GetPathRoot(root)).AvailableFreeSpace < selected.Sum(f=>f.size)*2+32L*1024*1024)
                    throw new IOException("目标磁盘空间不足，未开始替换文件。");
                StopOwned(root,token);
                var changes=new List<RepairChange>();
                try {
                    foreach(var file in selected) {
                        token.ThrowIfCancellationRequested(); string target=Safe(root,file.name),backup=Safe(Path.Combine(work,"backup"),file.name);
                        var change=new RepairChange {name=file.name,existed=File.Exists(target)};
                        if(change.existed) { Directory.CreateDirectory(Path.GetDirectoryName(backup)); File.Copy(target,backup); }
                        changes.Add(change); Write(Path.Combine(work,"journal.json"),changes);
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        string temp=target+".repair-new";
                        try { File.Copy(Safe(stage,file.name),temp,true); Core.ReplaceFile(temp,target); }
                        finally { if(File.Exists(temp)) File.Delete(temp); }
                        progress.Report(new Status {text="正在修复："+file.name,done=changes.Count,total=selected.Count});
                        if(failAfter>0 && changes.Count>=failAfter) throw new IOException("测试注入修复失败");
                    }
                    // 更新记录最后处理，所有旧记录备份到外部会话以便完整恢复。
                    foreach(string name in new[]{"pending.json"}) {
                        string relative=UpdateCache+"/"+name,target=Safe(root,relative);
                        if(!File.Exists(target)) continue;
                        string backup=Safe(Path.Combine(work,"backup"),relative); Directory.CreateDirectory(Path.GetDirectoryName(backup)); File.Copy(target,backup);
                        changes.Add(new RepairChange{name=relative,existed=true}); Write(Path.Combine(work,"journal.json"),changes); File.Delete(target);
                    }
                    progress.Report(new Status {text="正在进行修复后完整复检"});
                    var after=Inspect(root,manifest,token,progress,probe);
                    if(!after.Healthy) throw new IOException("修复后仍有问题："+String.Join("；",after.issues.Take(5)));
                    string marker=Safe(root,Installer.Marker),markerBackup=Safe(Path.Combine(work,"backup"),Installer.Marker);
                    Directory.CreateDirectory(Path.GetDirectoryName(markerBackup));File.Copy(marker,markerBackup);
                    changes.Add(new RepairChange{name=Installer.Marker,existed=true});Write(Path.Combine(work,"journal.json"),changes);
                    var state=Installer.ReadState(root); state.version=manifest.appVersion; state.releaseId=manifest.appReleaseId??manifest.releaseId;
                    state.files=(state.files??new string[0]).Concat(manifest.files.Select(file=>file.name)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
                    Installer.SaveState(state);
                    string message="修复完成，开始创作吧。";
                    try {Installer.RefreshBrand(root);}
                    catch(Exception integration) {Write(Path.Combine(work,"integration-warning.json"),new{message=integration.ToString()});message="程序已更新，部分快捷方式未能整理，请查看修复日志。";}
                    var result=new MaintenanceResult{status="repaired",message=message,root=root,session=work,repaired=true,issues=before.issues.ToArray()};
                    Write(Path.Combine(work,"result.json"),result); return result;
                } catch(Exception error) {
                    try { Rollback(root,work,changes); Write(Path.Combine(work,"result.json"),new {status="error",message=error.Message,rolledBack=true}); }
                    catch(Exception rollback) { throw new IOException("修复失败且回滚未完成，备份保留在 "+work+"："+rollback.Message,error); }
                    throw;
                }
            }
        }
        public static bool Route(string[] args,Manifest manifest) {
            if(!args.Contains("--inspect-root") && !args.Contains("--repair-root")) return false;
            string root=null,report=null,package=null; bool repair=false;
            for(int i=0;i<args.Length;i++) {
                if((args[i]=="--inspect-root" || args[i]=="--repair-root") && i+1<args.Length) { repair=args[i]=="--repair-root";root=args[++i]; }
                else if(args[i]=="--report" && i+1<args.Length) report=args[++i];
                else if(args[i]=="--package" && i+1<args.Length) package=args[++i];
                else throw new ArgumentException("不支持的维护参数："+args[i]);
            }
            if(String.IsNullOrEmpty(report)) throw new ArgumentException("命令行维护必须指定外部 --report 文件");
            report=Path.GetFullPath(report);root=Installer.Canonical(root);
            if(report.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)) throw new IOException("检查报告不能写入目标安装目录");
            try {
                var result=Run(root,manifest,repair,CancellationToken.None,new SilentProgress(),package);
                Write(report,result);Environment.ExitCode=result.status=="damaged"?2:0;
            } catch(Exception error) { Write(report,new {status="error",message=error.Message,root}); Environment.ExitCode=1; }
            return true;
        }
        sealed class SilentProgress : IProgress<Status> { public void Report(Status value) { } }
    }
}
