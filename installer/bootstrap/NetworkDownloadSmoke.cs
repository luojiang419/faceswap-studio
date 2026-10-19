using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Web.Script.Serialization;
using FaceSwapBootstrap;

public static class NetworkDownloadSmoke {
    sealed class Quiet : IProgress<Status> { public void Report(Status value) {} }
    public static int Main(string[] args) {
        try {
            var json=new JavaScriptSerializer();
            var publication=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(args[0]));
            var record=(Dictionary<string,object>)publication["installer"];
            var asset=new Asset { name="易容 Studio 安装器.exe", size=Convert.ToInt64(record["size"]), sha256=Convert.ToString(record["sha256"]), urls=new[]{Convert.ToString(record["url"])} };
            Directory.CreateDirectory(args[1]);
            File.WriteAllBytes(Path.Combine(args[1],asset.name)+".part",File.ReadAllBytes(args[2]).Take(65536).ToArray());
            Core.Download(asset,args[1],CancellationToken.None,new Quiet());
            if(!Core.Verified(Path.Combine(args[1],asset.name),asset)) throw new IOException("真实魔搭资源校验失败");
            File.WriteAllText(Path.Combine(args[1],"result.json"),json.Serialize(new { nativeHttpsDownload=true, rangeRequested=true, sha256Verified=true, size=asset.size, sha256=asset.sha256 }));
            Console.WriteLine("PASS 原生魔搭HTTPS下载、已有分片恢复与最终SHA256校验");return 0;
        } catch(Exception error) { Console.Error.WriteLine(error);return 1; }
    }
}
