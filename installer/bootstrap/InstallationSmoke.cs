using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;
using FaceSwapBootstrap;

// 真实安装验收：中文专用目录、真实 Python/模型、真实桌面首帧；系统集成写隔离位置。
public static class InstallationSmoke {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateHardLink(string target, string source, IntPtr unused);
    sealed class Log : IProgress<Status> {
        string previous;
        public void Report(Status state) { if (previous != state.text) { Console.WriteLine(state.text); previous=state.text; } }
    }
    static void Check(bool value, string message) { if (!value) throw new IOException(message); }
    [STAThread] public static int Main(string[] args) {
        var json = new JavaScriptSerializer { MaxJsonLength=32*1024*1024 };
        var manifest = json.Deserialize<Manifest>(File.ReadAllText(args[0]));
        string output=Path.GetFullPath(args[3]), root=Path.Combine(output,"中文 换脸工作台");
        string registry=Installer.UninstallKey+".Test."+Guid.NewGuid().ToString("N");
        Process child=null;
        Directory.CreateDirectory(output);
        try {
            Installer.ValidateDestinationCapacity(root);
            using(var lease=Installer.AcquireRoot(root)) {
                var owned=Installer.Begin(root,manifest,false,registry,true);
                string cache=Path.Combine(root,"data/cache/bootstrap".Replace('/',Path.DirectorySeparatorChar));
                Directory.CreateDirectory(cache);
                string package=Path.Combine(cache,manifest.package.name);
                if(!File.Exists(package) && !CreateHardLink(package,Path.GetFullPath(args[1]),IntPtr.Zero)) File.Copy(args[1],package);
                Core.Prepare(root,manifest,CancellationToken.None,new Log());
                Installer.InstallUninstaller(root,args[2]);
                File.Copy(Path.Combine(root,"facefusion.ico"),Path.Combine(root,"faceswap.ico"),true);
                File.Copy(Path.Combine(root,"facefusion.ico"),Path.Combine(root,"faceswap-installer.ico"),true);
                string session=Guid.NewGuid().ToString("N"), report=Path.Combine(root,"data/cache/install".Replace('/',Path.DirectorySeparatorChar),session+".json");
                Directory.CreateDirectory(Path.GetDirectoryName(report));
                Environment.SetEnvironmentVariable("FACESWAP_STUDIO_BRIDGE_PORT","52761");
                Environment.SetEnvironmentVariable("FACESWAP_STUDIO_BRIDGE_HOST","127.0.0.1");
                Environment.SetEnvironmentVariable("FACESWAP_STUDIO_ISOLATED","1");
                child=Installer.StartPreparation(root,report,session);
                using(var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(4)))
                    Installer.WaitForReady(root,report,session,child,timeout.Token,new Log()).GetAwaiter().GetResult();
                var paths=new IntegrationPaths { desktop=Path.Combine(output,"desktop"), startMenu=Path.Combine(output,"menu"), registryKey=registry };
                Installer.Complete(root,manifest,true,true,paths,report,session);
                owned=Installer.ReadState(root);
                Check(owned.state=="complete" && owned.shortcuts.Length==3,"安装登记或快捷方式验收失败");
                bool visible=Process.GetProcessesByName("faceswap_studio").Any(p=>{try{return Installer.SamePath(p.MainModule.FileName,Path.Combine(root,"faceswap studio/runtime/windows_app/current/faceswap_studio.exe".Replace('/',Path.DirectorySeparatorChar)))&&p.MainWindowHandle!=IntPtr.Zero;}catch{return false;}finally{p.Dispose();}});
                Check(visible,"真实桌面窗口未打开");
                File.WriteAllText(Path.Combine(output,"installation-result.json"),json.Serialize(new {
                    root, sourceArchiveReused=true, fullArchiveSha256=Core.Hash(args[1]),
                    realPythonAndModels=true, rendererAcknowledged=true, visibleWindow=true,
                    shortcutsAndIsolatedRegistry=true, ready=json.DeserializeObject(File.ReadAllText(report)),
                    testRegistry=registry, installId=owned.id, bootstrapPid=child.Id
                }));
                Console.WriteLine("PASS 真实运行包展开、Python/ONNX/模型自检、桌面首帧、Bridge健康与安装集成");
            }
            // 留下本次工作台，供真实魔搭独立升级验证；不触碰用户已有安装。
            return 0;
        } catch(Exception error) {
            Console.Error.WriteLine(error);
            if(child!=null) Installer.StopChild(child);
            Registry.CurrentUser.DeleteSubKeyTree(registry,false);
            return 1;
        }
    }
}
