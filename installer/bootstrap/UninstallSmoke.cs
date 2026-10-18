using System;
using System.IO;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using Microsoft.Win32;
using FaceSwapBootstrap;

public static class UninstallSmoke {
    public static int Main(string[] args) {
        try {
            var json=new JavaScriptSerializer { MaxJsonLength=32*1024*1024 };
            var report=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(args[0]));
            string root=Convert.ToString(report["root"]), id=Convert.ToString(report["installId"]), key=Convert.ToString(report["testRegistry"]);
            string personal=Path.Combine(root,"faceswap studio/data/output/升级保留.txt".Replace('/',Path.DirectorySeparatorChar));
            string config=Path.Combine(root,"faceswap studio/config/settings.json".Replace('/',Path.DirectorySeparatorChar));
            string content=File.ReadAllText(personal);
            Installer.Remove(root,id,false);
            if(File.ReadAllText(personal)!=content || !File.Exists(config)) throw new IOException("卸载未保留个人数据或配置");
            if(Directory.Exists(Path.Combine(root,".venv-win")) || Directory.Exists(Path.Combine(root,".assets")) || File.Exists(Path.Combine(root,"启动FaceSwap Studio.exe"))) throw new IOException("卸载残留应用文件");
            using(var entry=Registry.CurrentUser.OpenSubKey(key)) if(entry!=null) throw new IOException("测试卸载登记未清理");
            File.WriteAllText(args[1],json.Serialize(new { root, personalDataPreserved=true, configurationPreserved=true, applicationRemoved=true, isolatedRegistryRemoved=true }));
            Console.WriteLine("PASS 真实卸载、个人作品与配置保留、隔离登记清理");return 0;
        } catch(Exception error) {Console.Error.WriteLine(error);return 1;}
    }
}
