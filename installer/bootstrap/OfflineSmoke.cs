// 全量包真实安装验收：仅使用指定隔离目录、测试注册项与内部快捷方式。
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using FaceSwapBootstrap;

[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]

public static class OfflineSmoke {
    sealed class Quiet : IProgress<Status> { public void Report(Status status) { Console.WriteLine(status.text); } }
    public static int Main(string[] args) {
        try {
            AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling",false);
            AppContext.SetSwitch("Switch.System.IO.BlockLongPaths",false);
            string mode=args[0], root=Installer.Canonical(args[1]), distribution=Path.GetDirectoryName(Path.GetFullPath(args[2])), work=Path.GetFullPath(args[3]);
            var json=new JavaScriptSerializer { MaxJsonLength=32*1024*1024 };
            var manifest=json.Deserialize<Manifest>(File.ReadAllText(Path.Combine(distribution,"bootstrap-manifest.json"),Encoding.UTF8));
            Core.Validate(manifest); Directory.CreateDirectory(work);
            if(mode=="prepare") {
                string key=Installer.UninstallKey+".Test."+Guid.NewGuid().ToString("N");
                var state=Installer.Begin(root,manifest,false,key); state.registryKey=key; Installer.SaveState(state);
                Installer.InstallUninstaller(root,args[2]); Core.Prepare(root,manifest,CancellationToken.None,new Quiet());
                Installer.ExtractResource("app.ico",Path.Combine(root,"faceswap.ico"));
                Installer.ExtractResource("installer.ico",Path.Combine(root,"faceswap-installer.ico"));
                File.WriteAllText(Path.Combine(work,"prepared.json"),json.Serialize(new{root=root,key=key,offline=manifest.offline}));
            } else if(mode=="refresh") {
                var result=Maintenance.Run(root,manifest,true,CancellationToken.None,new Quiet(),
                    Path.Combine(distribution,manifest.package.name),Path.Combine(work,"refresh-"+Guid.NewGuid().ToString("N")));
                File.WriteAllText(Path.Combine(work,"refresh.json"),json.Serialize(result));
            } else if(mode=="complete") {
                var state=Installer.ReadState(root);
                var paths=new IntegrationPaths{registryKey=state.registryKey,desktop=Path.Combine(work,"desktop"),startMenu=Path.Combine(work,"menu")};
                const string session="0123456789abcdef0123456789abcdef";
                Installer.Complete(root,manifest,true,true,paths,Path.Combine(root,"data/cache/install/"+session+".json"),session);
                File.WriteAllText(Path.Combine(work,"completed.json"),json.Serialize(Installer.ReadState(root)));
            } else if(mode=="remove") {
                var state=Installer.ReadState(root); Installer.Remove(root,state.id,false);
                File.WriteAllText(Path.Combine(work,"uninstall.json"),json.Serialize(new{root=root,removed=true,personalPreserved=File.Exists(Path.Combine(root,"faceswap studio/data/output/proof.txt"))}));
            } else throw new ArgumentException("未知验收阶段");
            return 0;
        } catch(Exception error) { Console.Error.WriteLine(error);return 1; }
    }
}
