using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal static class InstallationIntegration {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer{MaxJsonLength=64*1024*1024};
    static string Full(string path) {return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);}
    static bool Same(string a,string b) {return String.Equals(Full(a),Full(b),StringComparison.OrdinalIgnoreCase);}
    static Dictionary<string,object> Read(string file) {return Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file));}
    static string Value(Dictionary<string,object> data,string name) {object value;return data.TryGetValue(name,out value)?Convert.ToString(value):null;}
    static IEnumerable<string> List(Dictionary<string,object> data,string name) {object value;return data.TryGetValue(name,out value)&&value is IEnumerable?((IEnumerable)value).Cast<object>().Select(Convert.ToString):Enumerable.Empty<string>();}
    static void Write(string file,object data) {string temp=file+".integrating";File.WriteAllText(temp,Json.Serialize(data));if(File.Exists(file))File.Replace(temp,file,null);else File.Move(temp,file);}
    static string Hash(string file) {using(var hash=SHA256.Create())using(var stream=File.OpenRead(file))return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-","").ToLowerInvariant();}
    static void UpdateUninstaller(string root,string session,Dictionary<string,object> manifest) {
        object raw;if(!manifest.TryGetValue("installer",out raw)||raw==null)return;
        var asset=(Dictionary<string,object>)raw;string hash=Value(asset,"sha256");long size=Convert.ToInt64(asset["size"]);
        var uri=new Uri(Value(asset,"url"));
        bool testing=Environment.GetEnvironmentVariable("FACESWAP_STUDIO_UPDATE_TEST")=="1"&&uri.Scheme=="http"&&(uri.Host=="127.0.0.1"||uri.Host=="localhost");
        if((!testing&&(uri.Scheme!="https"||uri.Host!="modelscope.cn"))||size<=0||size>16*1024*1024||!System.Text.RegularExpressions.Regex.IsMatch(hash,"^[a-f0-9]{64}$"))throw new IOException("安装维护入口信息无效");
        string target=Path.Combine(root,"uninstall.exe");if(File.Exists(target)&&new FileInfo(target).Length==size&&Hash(target)==hash)return;
        string cache=Path.Combine(session,"baseline-installer.exe");
        if(!File.Exists(cache)||new FileInfo(cache).Length!=size||Hash(cache)!=hash) {
            ServicePointManager.SecurityProtocol|=SecurityProtocolType.Tls12;
            var request=(HttpWebRequest)WebRequest.Create(uri);request.Proxy=null;request.Timeout=30000;request.ReadWriteTimeout=30000;request.UserAgent="Yirong-Studio-Update";
            using(var response=request.GetResponse())using(var input=response.GetResponseStream())using(var output=File.Create(cache)) {
                var buffer=new byte[65536];long received=0;int count;
                while((count=input.Read(buffer,0,buffer.Length))>0) {received+=count;if(received>size)throw new IOException("安装维护入口超过声明大小");output.Write(buffer,0,count);}
            }
            if(new FileInfo(cache).Length!=size||Hash(cache)!=hash)throw new IOException("安装维护入口校验失败");
        }
        string backup=Path.Combine(session,"integration-backup");Directory.CreateDirectory(backup);
        if(File.Exists(target)&&!File.Exists(Path.Combine(backup,"uninstall.exe")))File.Copy(target,Path.Combine(backup,"uninstall.exe"));
        string temp=target+".integrating";File.Copy(cache,temp,true);if(File.Exists(target))File.Replace(temp,target,null);else File.Move(temp,target);
    }
    static object Invoke(object target,string name,BindingFlags flags,params object[] args) {return target.GetType().InvokeMember(name,flags,null,target,args);}
    static string ShortcutTarget(object shell,string file) {
        object link=null;try {link=Invoke(shell,"CreateShortcut",BindingFlags.InvokeMethod,file);return Convert.ToString(Invoke(link,"TargetPath",BindingFlags.GetProperty));}
        finally {if(link!=null)Marshal.FinalReleaseComObject(link);}
    }
    static string MakeShortcut(object shell,string folder,string title,string target,string root,string arguments) {
        Directory.CreateDirectory(folder);
        for(int index=1;index<100;index++) {
            string file=Path.Combine(folder,title+(index==1?"":" ("+index+")")+".lnk");
            if(File.Exists(file)) {string existing=ShortcutTarget(shell,file);if(String.IsNullOrEmpty(existing)||!Same(existing,target))continue;}
            object link=null;try {
                link=Invoke(shell,"CreateShortcut",BindingFlags.InvokeMethod,file);
                Invoke(link,"TargetPath",BindingFlags.SetProperty,target);Invoke(link,"WorkingDirectory",BindingFlags.SetProperty,root);
                Invoke(link,"Arguments",BindingFlags.SetProperty,arguments);Invoke(link,"IconLocation",BindingFlags.SetProperty,Path.Combine(root,"facefusion.ico"));
                Invoke(link,"Save",BindingFlags.InvokeMethod);return file;
            }finally {if(link!=null)Marshal.FinalReleaseComObject(link);}
        }
        throw new IOException("无法为易容 Studio 创建不冲突的快捷方式");
    }
    public static void Refresh(string root,string session) {
        root=Full(root);session=Full(session);
        if(!session.StartsWith(Full(Path.Combine(root,"faceswap studio/data/cache/updates"))+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new IOException("更新会话不属于当前安装");
        if(Value(Read(Path.Combine(session,"status.json")),"status")!="complete")throw new IOException("更新未完成，不能迁移安装入口");
        string marker=Path.Combine(root,".faceswap-install.json");if(!File.Exists(marker))return;
        using(var lease=new FileStream(Path.Combine(session,"integration.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None)) {
            var state=Read(marker);var config=Read(Path.Combine(root,"update-config.json"));
            var envelope=Read(Path.Combine(session,"envelope.json"));var manifest=Json.Deserialize<Dictionary<string,object>>(Value(envelope,"payload"));
            if(Value(state,"product")!="faceswap-studio"||Value(state,"state")!="complete"||!Same(Value(state,"root"),root)||Value(manifest,"releaseId")!=Value(config,"releaseId"))throw new IOException("安装身份与更新版本不匹配");
            string key=Value(state,"registryKey")??@"Software\Microsoft\Windows\CurrentVersion\Uninstall\FaceSwapStudio";
            const string allowed=@"Software\Microsoft\Windows\CurrentVersion\Uninstall\FaceSwapStudio";
            if(key!=allowed&&!System.Text.RegularExpressions.Regex.IsMatch(key,"^"+System.Text.RegularExpressions.Regex.Escape(allowed)+@"\.Test\.[a-f0-9]{32}$"))throw new IOException("卸载登记路径无效");
            var records=((IEnumerable)manifest["files"]).Cast<object>().Cast<Dictionary<string,object>>().ToArray();
            foreach(var record in records) {string path=Full(Path.Combine(root,Value(record,"path").Replace('/',Path.DirectorySeparatorChar)));if(!path.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new IOException("更新文件超出安装目录");}
            string entry=Path.Combine(root,"易容 Studio.exe"),legacy=Path.Combine(root,"启动FaceSwap Studio.exe");
            bool alias=false;
            if(File.Exists(entry)&&!List(state,"files").Contains("易容 Studio.exe",StringComparer.OrdinalIgnoreCase)&&
                !records.Any(item=>Value(item,"path")=="易容 Studio.exe")&&(!File.Exists(legacy)||Hash(entry)!=Hash(legacy)))throw new IOException("同名启动文件不属于本软件，未改写入口");
            UpdateUninstaller(root,session,manifest);
            if(!File.Exists(entry)) {
                var record=records.FirstOrDefault(item=>Value(item,"path")=="启动FaceSwap Studio.exe");
                if(record==null||!File.Exists(legacy)||Hash(legacy)!=Value(record,"sha256"))throw new IOException("旧启动入口与已验证更新不一致");
                File.Copy(legacy,entry);alias=true;
            }
            state["files"]=List(state,"files").Concat(records.Select(item=>Value(item,"path"))).Concat(new[]{"易容 Studio.exe"}).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if(File.Exists(Path.Combine(root,"uninstall.exe")))state["files"]=List(state,"files").Concat(new[]{"uninstall.exe"}).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            state["version"]=manifest["version"];state["releaseId"]=manifest["releaseId"];Write(marker,state);
            var shortcuts=new List<string>(List(state,"shortcuts"));object shell=null;
            try {
                if(shortcuts.Count>0)shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell",true));
                foreach(string file in shortcuts.ToArray()) {
                    if(Path.GetExtension(file).ToLowerInvariant()!=".lnk"||!File.Exists(file))continue;
                    string target=ShortcutTarget(shell,file);
                    bool app=!String.IsNullOrEmpty(target)&&(Same(target,legacy)||Same(target,entry));
                    bool uninstall=!String.IsNullOrEmpty(target)&&Same(target,Path.Combine(root,"uninstall.exe"));
                    if(!app&&!uninstall)continue;
                    string title=app?"易容 Studio":"卸载 易容 Studio",folder=Path.GetDirectoryName(file);
                    string oldMenu=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"FaceSwap Studio");
                    if(Same(folder,oldMenu))folder=Path.Combine(Path.GetDirectoryName(oldMenu),"易容 Studio");
                    string desired=app?entry:Path.Combine(root,"uninstall.exe");
                    if(Path.GetFileNameWithoutExtension(file)==title&&Same(target,desired))continue;
                    string replacement=MakeShortcut(shell,folder,title,desired,root,app?"--faceswap-run":"--uninstall");
                    if(!shortcuts.Any(item=>Same(item,replacement)))shortcuts.Add(replacement);
                    state["shortcuts"]=shortcuts.ToArray();Write(marker,state);
                    if(!Same(file,replacement)) {File.Delete(file);shortcuts.Remove(file);}
                    if(Same(Path.GetDirectoryName(file),oldMenu)&&Directory.Exists(oldMenu)&&!Directory.EnumerateFileSystemEntries(oldMenu).Any())Directory.Delete(oldMenu);
                }
            }finally {if(shell!=null)Marshal.FinalReleaseComObject(shell);}
            using(var registry=Registry.CurrentUser.OpenSubKey(key,true)) {
                if(registry!=null&&Convert.ToString(registry.GetValue("InstallId"))==Value(state,"id")&&Same(Convert.ToString(registry.GetValue("InstallLocation")),root)) {
                    registry.SetValue("DisplayName","易容 Studio");registry.SetValue("Publisher","易容 Studio");
                    registry.SetValue("DisplayVersion",Value(state,"version"));
                }
            }
            state["shortcuts"]=shortcuts.ToArray();Write(marker,state);
            Write(Path.Combine(session,"integration-result.json"),new{ok=true,root,releaseId=Value(config,"releaseId"),canonicalEntryCreated=alias,trackedFiles=List(state,"files").Count()});
        }
    }
}
