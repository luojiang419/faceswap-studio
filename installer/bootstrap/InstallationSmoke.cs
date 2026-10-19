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
    static int FreePort() {
        var listener=new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback,0);
        listener.Start(); int port=((System.Net.IPEndPoint)listener.LocalEndpoint).Port; listener.Stop(); return port;
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
                if(manifest.application!=null && args.Length>4) {
                    string application=Path.Combine(cache,manifest.application.name);
                    if(!File.Exists(application) && !CreateHardLink(application,Path.GetFullPath(args[4]),IntPtr.Zero)) File.Copy(args[4],application);
                }
                Core.Prepare(root,manifest,CancellationToken.None,new Log());
                int bridgePort=FreePort(), corePort=FreePort();
                string settings=Path.Combine(root,"faceswap studio/runtime/settings.json".Replace('/',Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(settings));
                File.WriteAllText(settings,json.Serialize(new { facefusion_port=corePort }));
                Installer.InstallUninstaller(root,args[2]);
                File.Copy(Path.Combine(root,"facefusion.ico"),Path.Combine(root,"faceswap.ico"),true);
                File.Copy(Path.Combine(root,"facefusion.ico"),Path.Combine(root,"faceswap-installer.ico"),true);
                string session=Guid.NewGuid().ToString("N"), report=Path.Combine(root,"data/cache/install".Replace('/',Path.DirectorySeparatorChar),session+".json");
                Directory.CreateDirectory(Path.GetDirectoryName(report));
                Environment.SetEnvironmentVariable("FACESWAP_STUDIO_BRIDGE_PORT",bridgePort.ToString());
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
                bool brandedWindow=Process.GetProcessesByName("faceswap_studio").Any(p=>{try{return Installer.SamePath(p.MainModule.FileName,Path.Combine(root,"faceswap studio/runtime/windows_app/current/faceswap_studio.exe".Replace('/',Path.DirectorySeparatorChar)))&&p.MainWindowTitle=="易容 Studio";}catch{return false;}finally{p.Dispose();}});
                Check(brandedWindow,"真实窗口标题未改为易容 Studio");
                Check(owned.shortcuts.All(p=>!Path.GetFileName(p).Contains("FaceSwap")),"快捷方式仍包含旧品牌");
                using(var entry=Registry.CurrentUser.OpenSubKey(registry)) Check(Convert.ToString(entry.GetValue("DisplayName"))=="易容 Studio","卸载登记仍包含旧品牌");
                bool coreReady=false;
                using(var web=new System.Net.WebClient()) {
                    web.Proxy=null;
                    for(int attempt=0;attempt<90;attempt++) {
                        var status=json.Deserialize<System.Collections.Generic.Dictionary<string,object>>(web.DownloadString("http://127.0.0.1:"+bridgePort+"/facefusion/status"));
                        if(Convert.ToString(status["state"])=="ready") { coreReady=true; break; }
                        if(Convert.ToString(status["state"])=="failed") throw new IOException("安装后的核心启动失败："+json.Serialize(status));
                        Thread.Sleep(1000);
                    }
                    Check(coreReady,"安装后的核心启动超时");
                    Check(web.DownloadString("http://127.0.0.1:"+corePort+"/config").Contains("alphaface_256"),"核心 WebUI 配置验收失败");
                }
                File.WriteAllText(Path.Combine(output,"installation-result.json"),json.Serialize(new {
                    root, sourceArchiveReused=true, fullArchiveSha256=Core.Hash(args[1]),
                    realPythonAndModels=true, rendererAcknowledged=true, visibleWindow=true, brandedWindow, coreReady, bridgePort, corePort,
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
