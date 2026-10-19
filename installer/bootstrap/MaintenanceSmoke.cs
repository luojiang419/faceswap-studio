using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using FaceSwapBootstrap;

// 从最终运行包准备隔离安装，不登记真实快捷方式/注册表，不启动用户界面。
public static class MaintenanceSmoke {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CreateHardLink(string target,string source,IntPtr unused);
    sealed class Log : IProgress<Status> { public void Report(Status value) {Console.WriteLine(value.text);} }
    public static int Main(string[] args) {
        try {
            var json=new JavaScriptSerializer{MaxJsonLength=64*1024*1024};
            var manifest=json.Deserialize<Manifest>(File.ReadAllText(args[0]));
            string root=Path.GetFullPath(args[3]);Directory.CreateDirectory(root);
            using(var lease=Installer.AcquireRoot(root)) {
                var state=Installer.Begin(root,manifest,false,lockHeld:true);
                string cache=Path.Combine(root,"data/cache/bootstrap"),package=Path.Combine(cache,manifest.package.name);
                Directory.CreateDirectory(cache);
                if(!CreateHardLink(package,Path.GetFullPath(args[1]),IntPtr.Zero)) File.Copy(args[1],package);
                Core.Prepare(root,manifest,CancellationToken.None,new Log());
                File.WriteAllText(Path.Combine(root,".venv-win/pyvenv.cfg"),"home = "+Path.Combine(root,".python")+"\ninclude-system-site-packages = false\nexecutable = "+Path.Combine(root,".python/python.exe")+"\n");
                Installer.InstallUninstaller(root,Path.GetFullPath(args[2]));
                File.Copy(Path.Combine(root,"facefusion.ico"),Path.Combine(root,"faceswap.ico"));
                File.Copy(Path.Combine(root,"facefusion.ico"),Path.Combine(root,"faceswap-installer.ico"));
                state.state="complete";Installer.SaveState(state);
            }
            Console.WriteLine("PASS 已准备真实包的隔离维护夹具；未登记系统集成或假报首次安装握手。");return 0;
        } catch(Exception error) {Console.Error.WriteLine(error);return 1;}
    }
}
