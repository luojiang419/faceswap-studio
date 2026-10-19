using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using FaceSwapBootstrap;

public static class MaintenanceTests {
    sealed class Quiet : IProgress<Status> { public void Report(Status value) { } }
    sealed class CancelAfterWrite : IProgress<Status> {
        public CancellationTokenSource cancellation=new CancellationTokenSource();
        public void Report(Status value) { if(value.text.StartsWith("正在修复：")) cancellation.Cancel(); }
    }
    sealed class Fixture : IDisposable {
        public string directory,root,work,package;
        public Manifest manifest;
        public Fixture(string output) {
            directory=Path.Combine(output,Guid.NewGuid().ToString("N")); root=Path.Combine(directory,"中文 安装目录"); work=Path.Combine(directory,"repair-session"); package=Path.Combine(directory,"runtime.zip");
            Directory.CreateDirectory(root);
            Put("app.exe","good-app"); Put("data.bin","good-data"); Put(".assets/models/model.onnx","trusted-model");
            Put(".venv-win/Scripts/python.exe","standalone-recovery-test");
            Put(".venv-win/pyvenv.cfg","home = "+Path.Combine(root,".python")+"\n");
            Put("VERSION","0.1.3");Put("update-config.json","{\"releaseId\":\"20261019040000\",\"publicKey\":\"trusted-key\",\"autoCheck\":false}");
            manifest=new Manifest{protocol=1,releaseId="20261019040000",appReleaseId="20261019040000",appVersion="0.1.3",publicKey="trusted-key",entry="app.exe"};
            manifest.files=Directory.GetFiles(root,"*",SearchOption.AllDirectories).Select(path=>new Asset{name=path.Substring(root.Length+1).Replace('\\','/'),size=new FileInfo(path).Length,sha256=Core.Hash(path)}).OrderBy(f=>f.name).ToArray();
            using(var zip=ZipFile.Open(package,ZipArchiveMode.Create)) foreach(var file in manifest.files) zip.CreateEntryFromFile(Path.Combine(root,file.name),"FaceSwapStudio/"+file.name);
            manifest.package=new Asset{name="runtime.zip",size=new FileInfo(package).Length,sha256=Core.Hash(package),urls=new[]{"https://example.invalid/runtime.zip"}};
            Installer.SaveState(new InstallState{root=root,id=Guid.NewGuid().ToString("N"),state="complete",version=manifest.appVersion,releaseId=manifest.releaseId});
        }
        public void Put(string name,string text) { string file=Path.Combine(root,name);Directory.CreateDirectory(Path.GetDirectoryName(file));File.WriteAllText(file,text); }
        public string Get(string name) { return File.ReadAllText(Path.Combine(root,name)); }
        public MaintenanceResult Run(bool repair=false,int fail=-1) {
            if(Directory.Exists(work)) work=Path.Combine(directory,"repair-"+Guid.NewGuid().ToString("N"));
            return Maintenance.Run(root,manifest,repair,CancellationToken.None,new Quiet(),package,work,false,fail);
        }
        public Process Updater(string status="complete",bool sameRoot=true,bool busy=false) {
            string session=Path.Combine(root,"faceswap studio/data/cache/updates/20260101000000");Directory.CreateDirectory(session);
            var json=new JavaScriptSerializer();
            File.WriteAllText(Path.Combine(session,"session.json"),json.Serialize(new{root=sameRoot?root:directory}));
            File.WriteAllText(Path.Combine(session,"status.json"),json.Serialize(new{status}));
            string exe=Path.Combine(session,"FaceSwapStudioUpdater.exe"),ready=Path.Combine(session,"window-ready");
            File.Copy(Process.GetCurrentProcess().MainModule.FileName,exe);
            var child=Process.Start(new ProcessStartInfo(exe,"--updater-fixture \""+ready+"\" "+(busy?"busy":"idle")){UseShellExecute=false,CreateNoWindow=true});
            for(int i=0;i<100 && !File.Exists(ready) && !child.HasExited;i++) Thread.Sleep(50);
            if(!File.Exists(ready)) throw new Exception("测试更新器未启动");
            return child;
        }
        public void Dispose() { }
    }
    static void Check(bool value,string reason) {if(!value) throw new Exception(reason);}
    static void Reject(Action action,string text) {try {action();} catch(Exception error) {Check(error.Message.Contains(text),error.ToString());return;}throw new Exception("未拒绝："+text);}
    static void ReleaseUpdater(Process child) {
        try {
            if(child.HasExited) return;
            File.WriteAllText(Path.Combine(Path.GetDirectoryName(child.MainModule.FileName),"release-worker"),"");
            if(!child.WaitForExit(5000)) child.Kill();
        } finally {child.Dispose();}
    }
    [STAThread]
    public static int Main(string[] args) {
        if(args[0]=="--updater-fixture") {
            using(var form=new Form{Text="易容 Studio · 软件更新",Opacity=0,ShowInTaskbar=false})
            using(var timer=new System.Windows.Forms.Timer{Interval=100}) {
                form.Shown+=(s,e)=>File.WriteAllText(args[1],"ready");
                form.FormClosing+=(s,e)=>{if(args[2]=="busy" && !File.Exists(Path.Combine(Path.GetDirectoryName(args[1]),"release-worker"))) e.Cancel=true;};
                timer.Tick+=(s,e)=>{if(File.Exists(Path.Combine(Path.GetDirectoryName(args[1]),"release-worker"))) form.Close();};
                timer.Start();
                Application.Run(form);
            }
            return 0;
        }
        string output=Path.GetFullPath(args[0]);Directory.CreateDirectory(output);int passed=0;
        Action<string,Action<Fixture>> test=(name,action)=>{using(var f=new Fixture(output)) {action(f);Console.WriteLine("PASS "+name);passed++;}};
        try {
            test("正常安装只读检查，无日志目录、无修复锁、无文件写入",f=>{
                var before=Directory.GetFiles(f.root,"*",SearchOption.AllDirectories).ToDictionary(p=>p,p=>new FileInfo(p).LastWriteTimeUtc);
                var result=f.Run(true);Check(result.status=="healthy" && !result.repaired,"健康状态错误");
                Check(!Directory.Exists(f.work),"正常安装创建了修复会话");
                Check(before.Count==Directory.GetFiles(f.root,"*",SearchOption.AllDirectories).Length,"正常安装增加文件");
                Check(before.All(p=>File.GetLastWriteTimeUtc(p.Key)==p.Value),"正常检查改写了文件");
            });
            test("只检查发现同长度损坏，不自动写入",f=>{
                f.Put("app.exe","evil-app");var result=f.Run();Check(result.status=="damaged" && f.Get("app.exe")=="evil-app","检查误修复或漏检");
            });
            test("只读检查不关闭已完成的旧更新器",f=>{
                var child=f.Updater();try {f.Run();Check(!child.HasExited,"只读检查关闭了更新器");} finally {ReleaseUpdater(child);}
            });
            test("修复正常关闭本目录已完成更新器并继续替换",f=>{
                var child=f.Updater();try {
                    f.Put("app.exe","evil-app");Check(f.Run(true).repaired,"残留更新器阻止修复");
                    Check(child.WaitForExit(1000) && child.ExitCode==0,"更新器未正常退出");
                    Check(f.Get("app.exe")=="good-app","程序未替换");
                } finally {ReleaseUpdater(child);}
            });
            test("正在执行的更新事务不请求关闭",f=>{
                var child=f.Updater("installing");try {
                    Maintenance.CloseCompletedUpdaters(f.root,new List<Process>{child},CancellationToken.None);
                    Thread.Sleep(200);Check(!child.HasExited,"关闭了执行中事务");
                } finally {ReleaseUpdater(child);}
            });
            test("事务身份不匹配不关闭其他安装的更新器",f=>{
                var child=f.Updater(sameRoot:false);try {
                    Maintenance.CloseCompletedUpdaters(f.root,new List<Process>{child},CancellationToken.None);
                    Thread.Sleep(200);Check(!child.HasExited,"关闭了身份不匹配窗口");
                } finally {ReleaseUpdater(child);}
            });
            test("旧状态记录不能强杀仍繁忙的更新器",f=>{
                var child=f.Updater(busy:true);try {
                    Maintenance.CloseCompletedUpdaters(f.root,new List<Process>{child},CancellationToken.None);
                    Check(!child.HasExited,"强杀了繁忙更新器");
                } finally {ReleaseUpdater(child);}
            });
            test("独立恢复缺失的目标 Python，不调用损坏环境",f=>{
                File.Delete(Path.Combine(f.root,".venv-win/Scripts/python.exe"));var result=f.Run(true);
                Check(result.repaired && f.Get(".venv-win/Scripts/python.exe")=="standalone-recovery-test","未恢复 Python");
            });
            test("只替换坏文件，保留额外模型、作品与配置",f=>{
                f.Put("app.exe","evil-app"); f.Put(".assets/models/custom.onnx","my-model");f.Put("faceswap studio/data/output/作品.txt","my-work");f.Put("faceswap studio/config/settings.json","my-settings");f.Put("facefusion.ini","my-options");
                var result=f.Run(true);Check(result.status=="repaired" && f.Get("app.exe")=="good-app","未修复程序");
                Check(f.Get(".assets/models/custom.onnx")=="my-model" && f.Get("faceswap studio/data/output/作品.txt")=="my-work" && f.Get("faceswap studio/config/settings.json")=="my-settings" && f.Get("facefusion.ini")=="my-options","个人数据被修改");
            });
            test("路径修复针对当前安装，避免迁移后重复判坏",f=>{
                f.Put(".venv-win/pyvenv.cfg","home = X:\\missing\n"); f.Run(true);
                Check(f.Get(".venv-win/pyvenv.cfg").Contains(Path.Combine(f.root,".python")),"路径未修正");Check(f.Run().status=="healthy","修复后重复判坏");
            });
            test("新版发布禁止被旧修复包覆盖",f=>{
                f.Put("update-config.json","{\"releaseId\":\"20990101000000\",\"publicKey\":\"trusted-key\"}");
                Reject(()=>f.Run(true),"禁止降级");Check(f.Get("app.exe")=="good-app","拒绝后仍改写程序");
            });
            test("更新程序版本禁止降级",f=>{f.Put("VERSION","0.2.0");Reject(()=>f.Run(true),"版本高于");});
            test("损坏配置可用安装身份恢复，保留原自动更新偏好",f=>{
                f.Put("update-config.json","{\"releaseId\":\"20261019030000\",\"publicKey\":\"trusted-key\",\"autoCheck\":false}");
                f.Run(true);Check(f.Get("update-config.json").Contains("false"),"自动更新偏好丢失");Check(f.Run().status=="healthy","配置未修复");
                f.Put("update-config.json","broken-json");f.Run(true);Check(f.Run().status=="healthy","破损 JSON 未恢复");
            });
            test("旧安装更新后登记新文件归属并保存原身份备份",f=>{
                var original=Installer.ReadState(f.root);string id=original.id;
                Check(original.files.Length==0,"夹具应模拟缺少新归属记录的旧安装");
                f.Put("app.exe","evil-app");Check(f.Run(true).repaired,"更新未完成");
                var updated=Installer.ReadState(f.root);
                Check(updated.id==id&&updated.files.Contains("app.exe")&&updated.files.Contains(".assets/models/model.onnx"),"更新未登记新文件或覆盖身份");
                Check(File.Exists(Path.Combine(f.work,"backup",Installer.Marker)),"没有原安装身份备份");
            });
            test("拒绝校验错误的运行包，原程序不改变",f=>{
                f.Put("app.exe","evil-app");File.AppendAllText(f.package,"tamper");Reject(()=>f.Run(true),"校验失败");Check(f.Get("app.exe")=="evil-app","坏包覆盖了程序");
            });
            test("替换中失败完整回滚，并保留错误与备份",f=>{
                f.Put("app.exe","evil-app");f.Put("data.bin","evil-data");Reject(()=>f.Run(true,1),"测试注入");
                Check(f.Get("app.exe")=="evil-app" && f.Get("data.bin")=="evil-data","失败未回滚");Check(File.Exists(Path.Combine(f.work,"error.json")),"错误日志未保留");
            });
            test("替换中取消会回滚，不伪报完成",f=>{
                f.Put("app.exe","evil-app");f.Put("data.bin","evil-data");var progress=new CancelAfterWrite();
                try {Maintenance.Run(f.root,f.manifest,true,progress.cancellation.Token,progress,f.package,f.work,false);throw new Exception("取消未生效");}
                catch(OperationCanceledException) { }
                Check(f.Get("app.exe")=="evil-app" && f.Get("data.bin")=="evil-data","取消未回滚");
            });
            test("真实环境探测失败不假报正常，修复后探测失败会回滚",f=>{
                var inspect=Maintenance.Inspect(f.root,f.manifest,CancellationToken.None,new Quiet(),true);
                Check(!inspect.Healthy,"坏的 Python 被报告正常");f.Put("app.exe","evil-app");
                Reject(()=>Maintenance.Run(f.root,f.manifest,true,CancellationToken.None,new Quiet(),f.package,f.work,true),"修复后仍有问题");
                Check(f.Get("app.exe")=="evil-app","复检失败未回滚");
            });
            test("更新事务越界不修复，用户目录保持原样",f=>{
                f.Put("faceswap studio/data/cache/updates/pending.json","{\"session\":\"C:\\\\outside\"}");Reject(()=>f.Run(true),"不属于此安装目录");
            });
            test("不完整旧事务从可信包前向恢复，保留旧日志",f=>{
                string session=Path.Combine(f.root,"faceswap studio/data/cache/updates/old-session");Directory.CreateDirectory(session);
                var json=new JavaScriptSerializer();File.WriteAllText(Path.Combine(session,"session.json"),json.Serialize(new{root=f.root}));
                File.WriteAllText(Path.Combine(session,"journal.json"),"{\"changes\":[{\"path\":\"app.exe\",\"existed\":true}],\"status\":\"installing\"}");
                f.Put("faceswap studio/data/cache/updates/pending.json",json.Serialize(new{session}));f.Put("app.exe","evil-app");
                Check(f.Run(true).repaired && f.Get("app.exe")=="good-app","未前向恢复");
                Check(File.Exists(Path.Combine(session,"journal.json")) && !File.Exists(Path.Combine(f.root,"faceswap studio/data/cache/updates/pending.json")),"旧日志丢失或未清除阻塞标记");
            });
            Console.WriteLine("ALL PASSED: "+passed);return 0;
        } catch(Exception error) {Console.Error.WriteLine(error);return 1;}
    }
}
