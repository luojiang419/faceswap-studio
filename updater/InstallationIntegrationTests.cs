using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal static class InstallationIntegrationTests {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static void Put(string file,string value) {Directory.CreateDirectory(Path.GetDirectoryName(file));File.WriteAllText(file,value);}
    static void Save(string file,object value) {Put(file,Json.Serialize(value));}
    static string Hash(string file) {using(var hash=SHA256.Create())return BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(file))).Replace("-","").ToLowerInvariant();}
    static void Check(bool ok,string reason) {if(!ok)throw new Exception(reason);}
    static void Link(string file,string target) {
        Directory.CreateDirectory(Path.GetDirectoryName(file));object shell=null,link=null;
        try {shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));link=shell.GetType().InvokeMember("CreateShortcut",BindingFlags.InvokeMethod,null,shell,new object[]{file});link.GetType().InvokeMember("TargetPath",BindingFlags.SetProperty,null,link,new object[]{target});link.GetType().InvokeMember("Save",BindingFlags.InvokeMethod,null,link,null);}
        finally {if(link!=null)Marshal.FinalReleaseComObject(link);if(shell!=null)Marshal.FinalReleaseComObject(shell);}
    }
    [STAThread] static int Main(string[] args) {
        int passed=0;
        try {
            foreach(string scenario in new[]{"migrate","uncommitted","collision","unsafe-path","foreign-shortcut","maintenance-entry","bad-maintenance-entry"}) {
                string root=Path.GetFullPath(Path.Combine(args[0],scenario,"中文 安装"));Directory.CreateDirectory(root);
                string session=Path.Combine(root,"faceswap studio/data/cache/updates/20260101000002");Directory.CreateDirectory(session);
                string key=@"Software\Microsoft\Windows\CurrentVersion\Uninstall\FaceSwapStudio.Test."+Guid.NewGuid().ToString("N");
                string id=Guid.NewGuid().ToString("N"),legacy=Path.Combine(root,"启动FaceSwap Studio.exe"),entry=Path.Combine(root,"易容 Studio.exe");
                Put(legacy,"legacy launcher");Put(Path.Combine(root,"updater/new.py"),"new code");
                string personal=Path.Combine(root,"faceswap studio/data/output/保留.txt");Put(personal,"personal");
                string desktop=Path.Combine(root,"isolated-desktop"),oldLink=Path.Combine(desktop,"FaceSwap Studio.lnk");
                string foreign=Path.Combine(desktop,"易容 Studio.lnk"),other=Path.Combine(root,"other.exe");Put(other,"foreign app");
                Link(oldLink,scenario=="foreign-shortcut"?other:legacy);Link(foreign,other);
                if(scenario=="collision")Put(entry,"foreign canonical filename");
                Save(Path.Combine(root,"update-config.json"),new{releaseId="20260101000002"});
                var records=new[]{new{path="启动FaceSwap Studio.exe",sha256=Hash(legacy)},new{path=scenario=="unsafe-path"?"../outside":"updater/new.py",sha256=Hash(Path.Combine(root,"updater/new.py"))}};
                var manifest=new Dictionary<string,object>{{"version","0.1.3"},{"releaseId","20260101000002"},{"files",records}};
                TcpListener server=null;Thread network=null;
                if(scenario.EndsWith("maintenance-entry")) {
                    Put(Path.Combine(root,"uninstall.exe"),"old-uninstaller");
                    string trusted=Path.Combine(session,"test-new-installer.exe");Put(trusted,"new-maintenance-program");byte[] bytes=File.ReadAllBytes(trusted);
                    server=new TcpListener(IPAddress.Loopback,0);server.Start();int port=((IPEndPoint)server.LocalEndpoint).Port;
                    network=new Thread(()=>{try {using(var connection=server.AcceptTcpClient())using(var stream=connection.GetStream()) {var input=new byte[8192];stream.Read(input,0,input.Length);byte[] header=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: "+bytes.Length+"\r\nConnection: close\r\n\r\n");stream.Write(header,0,header.Length);stream.Write(bytes,0,bytes.Length);}}catch{}});network.Start();
                    Environment.SetEnvironmentVariable("FACESWAP_STUDIO_UPDATE_TEST","1");
                    manifest["installer"]=new{url="http://127.0.0.1:"+port+"/installer.exe",size=bytes.Length,sha256=scenario.StartsWith("bad")?new string('0',64):Hash(trusted)};
                }
                Save(Path.Combine(session,"envelope.json"),new{payload=Json.Serialize(manifest)});
                Save(Path.Combine(session,"status.json"),new{status=scenario=="uncommitted"?"installing":"complete"});
                string marker=Path.Combine(root,".faceswap-install.json");
                Save(marker,new{product="faceswap-studio",id,root,state="complete",version="0.1.3",releaseId="20260101000001",registryKey=key,files=new[]{"启动FaceSwap Studio.exe"},shortcuts=new[]{oldLink}});
                string before=File.ReadAllText(marker);
                using(var registry=Registry.CurrentUser.CreateSubKey(key)) {registry.SetValue("InstallId",id);registry.SetValue("InstallLocation",root);registry.SetValue("DisplayName","FaceSwap Studio");}
                try {
                    bool reject=scenario=="uncommitted"||scenario=="collision"||scenario=="unsafe-path"||scenario=="bad-maintenance-entry";
                    try {InstallationIntegration.Refresh(root,session);Check(!reject,"应拒绝的迁移通过了");}
                    catch(IOException) {Check(reject,"正常迁移失败");}
                    if(reject) {Check(File.ReadAllText(marker)==before,"失败时改写安装身份");Check(File.Exists(oldLink),"失败时删除原快捷方式");}
                    else {
                        var state=Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(marker));
                        string[] files=((IEnumerable)state["files"]).Cast<object>().Select(Convert.ToString).ToArray();
                        Check(files.Contains("易容 Studio.exe")&&files.Contains("updater/new.py"),"新文件没有进入卸载归属记录");
                        Check(Hash(entry)==Hash(legacy)&&Convert.ToString(state["id"])==id,"启动入口或安装身份错误");
                        Check(File.Exists(foreign),"覆盖其他应用同名快捷方式");
                        if(scenario=="migrate")Check(!File.Exists(oldLink)&&File.Exists(Path.Combine(desktop,"易容 Studio (2).lnk")),"没有安全迁移快捷方式");
                        if(scenario=="foreign-shortcut")Check(File.Exists(oldLink),"删除了其他应用的快捷方式");
                        InstallationIntegration.Refresh(root,session);
                        if(scenario=="maintenance-entry")Check(File.ReadAllText(Path.Combine(root,"uninstall.exe"))=="new-maintenance-program"&&File.ReadAllText(Path.Combine(session,"integration-backup/uninstall.exe"))=="old-uninstaller","维护入口更新或备份错误");
                        using(var registry=Registry.CurrentUser.OpenSubKey(key))Check(Convert.ToString(registry.GetValue("DisplayName"))=="易容 Studio","应用列表品牌未更新");
                    }
                    Check(File.ReadAllText(personal)=="personal","迁移破坏作品");
                    if(scenario=="bad-maintenance-entry")Check(File.ReadAllText(Path.Combine(root,"uninstall.exe"))=="old-uninstaller","坏维护入口覆盖旧卸载器");
                    Console.WriteLine("PASS "+scenario);passed++;
                }finally {Registry.CurrentUser.DeleteSubKeyTree(key,false);if(server!=null) {server.Stop();network.Join(3000);}Environment.SetEnvironmentVariable("FACESWAP_STUDIO_UPDATE_TEST",null);}
            }
            Console.WriteLine(passed+" installation integration migration tests passed");return 0;
        }catch(Exception error) {Console.Error.WriteLine(error);return 1;}
    }
}
