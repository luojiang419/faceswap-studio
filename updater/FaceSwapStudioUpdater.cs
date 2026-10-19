using System;

using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using System.Windows.Forms;
using System.Threading;
using System.Security.Cryptography;
using System.Text;
using FaceSwapBootstrap;

[assembly: System.Reflection.AssemblyTitle("易容 Studio 软件更新")]
[assembly: System.Reflection.AssemblyProduct("易容 Studio")]

internal sealed class UpdateWindow : StudioUpdateSurface {
    readonly Label title = new Label(), detail = new Label();
    readonly ProgressBar progress = new ProgressBar();
    readonly SoftButton close;
    Process child;
    bool complete;
    string session, python;
    public UpdateWindow(string directory, string interpreter) {
        session = directory; python = interpreter;
        Text = "易容 Studio · 软件更新"; Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        title.Text = "正在更新易容 Studio";detail.Text = "正在准备更新，请稍候…";
        VersionText="更新已下载，正在安装";ReleaseNotes="完成更新后将自动重启，作品、人物形象与设置会保留。";
        close=ReturnAction;close.Text="关闭";close.Enabled=false;
        PrimaryAction.Visible=SecondaryAction.Visible=false;
        progress.Visible=false;Controls.Add(progress);close.Click+=(s,e)=>Close();SyncSurface();
        FormClosing += (s,e) => { if (!complete) e.Cancel = true; };
        Shown += (s,e) => {StartUpdate();SyncSurface();};
    }
    void SyncSurface() {StatusTitle=title.Text;StatusDetail=detail.Text;Fraction=progress.Value/100d;View=complete?(progress.Value==100?"ready":"error"):"working";IsBusy=!complete;RefreshSurface();}
    void Dispatch(Action action) { if (!IsDisposed && IsHandleCreated) BeginInvoke((Action)(()=>{action();SyncSurface();})); }
    void StartUpdate() {
        try {
            var start = new ProcessStartInfo(python, "\"" + Path.Combine(session,"transaction.py") + "\" \"" + session + "\"") {
                WorkingDirectory = session, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            start.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
            child = new Process { StartInfo = start, EnableRaisingEvents = true };
            child.OutputDataReceived += (s,e) => {
                if (e.Data == null) return;
                try {
                    var value = new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(e.Data);
                    Dispatch(() => { detail.Text = Convert.ToString(value["message"]); object number;
                        if(value.TryGetValue("progress",out number)) progress.Value=Math.Max(0,Math.Min(100,Convert.ToInt32(number))); });
                } catch { }
            };
            child.ErrorDataReceived += (s,e) => { if(e.Data != null) File.AppendAllText(Path.Combine(session,"updater.log"),e.Data+Environment.NewLine); };
            child.Exited += (s,e) => Dispatch(() => {
                complete = true; close.Enabled = true;
                if(child.ExitCode == 0) { title.Text="更新完成"; detail.Text="工作台已重启，并通过启动检查。"; progress.Value=100; }
                else { title.Text="更新未完成"; detail.Text="已尝试恢复原版本。请查看更新日志后重试。\n"+session; }
            });
            child.Start(); child.BeginOutputReadLine(); child.BeginErrorReadLine();
        } catch (Exception error) { complete=true; close.Enabled=true; title.Text="无法启动更新"; detail.Text=error.Message; }
    }
    [STAThread] static int Main(string[] args) {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if(args.Length==3 && (args[0]=="--offer" || args[0]=="--install-offer")) {
            try {
                string directory=Path.GetFullPath(args[1]);
                if(!File.Exists(Path.Combine(directory,"prompt.json")) || !File.Exists(Path.Combine(directory,"offer.py")) || !File.Exists(args[2])) return 2;
                string identity;
                var offer=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(directory,"prompt.json")));
                using(var hash=SHA256.Create()) identity=BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(Convert.ToString(offer["root"])).ToUpperInvariant()))).Replace("-","");
                using(var mutex=new Mutex(false,"Local\\Yirong-Studio-Update-"+identity)) {
                    if(!mutex.WaitOne(0)) return 0;
                    Application.Run(new UpdateOfferWindow(directory,Path.GetFullPath(args[2]),args[0]=="--install-offer"));
                }
                return 0;
            } catch(Exception error) { MessageBox.Show(error.Message,"易容 Studio · 软件更新",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
        }
        if(args.Length!=2 || !File.Exists(Path.Combine(args[0],"session.json")) || !File.Exists(args[1])) return 2;
        Application.Run(new UpdateWindow(Path.GetFullPath(args[0]),Path.GetFullPath(args[1]))); return 0;
    }
}

internal sealed class UpdateOfferWindow : StudioUpdateSurface {
    readonly Label title=new Label(), detail=new Label();
    readonly ProgressBar progress=new ProgressBar();
    readonly SoftButton now, later, close;
    readonly string session, python, root;
    readonly bool startup;
    Process child;
    bool busy, updated, current;
    public UpdateOfferWindow(string directory,string interpreter,bool automatic) {
        session=directory;python=interpreter;startup=automatic;
        var prompt=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(session,"prompt.json")));
        root=Path.GetFullPath(Convert.ToString(prompt["root"]));
        Text="易容 Studio · 软件更新";Name="update-offer";
        Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        title.Text="发现新的功能与改进";
        VersionText=Convert.ToString(prompt["current_version"])==Convert.ToString(prompt["latest_version"])?"版本 "+prompt["latest_version"]+" · 功能更新":"当前 "+prompt["current_version"]+"  →  "+prompt["latest_version"];
        ReleaseNotes=Convert.ToString(prompt["notes"]);
        detail.Text="现在更新即可体验，也可以留到下次启动。";
        now=PrimaryAction;later=SecondaryAction;close=ReturnAction;
        later.Name="update-later";later.Text="下次启动更新";later.Click+=(s,e)=>StartChoice("later");
        now.Name="update-now";now.Text="现在更新  →";now.Click+=(s,e)=>StartChoice("now");
        close.Name="close-update";close.Text="继续使用";close.Visible=false;close.Click+=(s,e)=>Close();
        progress.Visible=false;Controls.Add(progress);
        AcceptButton=now;
        FormClosing+=(s,e)=>{if(busy) e.Cancel=true;else if(startup && !updated) ReturnToStudio();};
        Shown+=(s,e)=>{if(startup) BeginInvoke((Action)(()=>StartChoice("now")));else now.Focus();};
        SyncSurface();
    }
    void SyncSurface() {StatusTitle=title.Text;StatusDetail=detail.Text;Fraction=progress.Value/100d;View=busy?(progress.Value>=28?"working":"downloading"):updated||current?"ready":close.Visible?"error":"idle";IsBusy=busy;RefreshSurface();}
    void Dispatch(Action action) {if(!IsDisposed && IsHandleCreated) BeginInvoke((Action)(()=>{action();SyncSurface();}));}
    void ReturnToStudio() {
        string executable=Path.Combine(root,"易容 Studio.exe");
        if(!File.Exists(executable)) executable=Path.Combine(root,"启动FaceSwap Studio.exe");
        if(File.Exists(executable)) {
            var start=new ProcessStartInfo(executable,"--faceswap-run --faceswap-show"){WorkingDirectory=root,UseShellExecute=false};
            start.EnvironmentVariables["FACESWAP_STUDIO_SKIP_DEFERRED_UPDATE"]="1";
            Process.Start(start);
        }
    }
    void StartChoice(string action) {
        if(busy)return;
        busy=true;now.Enabled=later.Enabled=false;close.Visible=false;progress.Value=0;
        title.Text=action=="later"?"正在安排下次更新":"正在更新易容 Studio";
        detail.Text=action=="later"?"保存选择后即可继续使用。":"正在下载并校验更新，完成后将自动重启。";
        SyncSurface();
        try {
            var start=new ProcessStartInfo(python,"\""+Path.Combine(session,"offer.py")+"\" \""+session+"\" "+action) {
                WorkingDirectory=session,UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true
            };
            start.EnvironmentVariables["PYTHONIOENCODING"]="utf-8";
            child=new Process{StartInfo=start};
            child.OutputDataReceived+=(s,e)=>{
                if(e.Data==null)return;
                try {
                    var value=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(e.Data);
                    Dispatch(()=>{detail.Text=Convert.ToString(value["message"]);object number;if(value.TryGetValue("progress",out number)) progress.Value=Math.Max(0,Math.Min(100,Convert.ToInt32(number)));});
                } catch { }
            };
            child.ErrorDataReceived+=(s,e)=>{if(e.Data!=null) File.AppendAllText(Path.Combine(session,"updater.log"),e.Data+Environment.NewLine);};
            child.Start();child.BeginOutputReadLine();child.BeginErrorReadLine();
            ThreadPool.QueueUserWorkItem(_=>{
                child.WaitForExit();int code=child.ExitCode;
                Dispatch(()=>{
                    busy=false;
                    if(code==0 && action=="later") {Close();return;}
                    if(code==0) {updated=true;title.Text="更新完成";detail.Text="易容 Studio 已重启，并通过启动检查。";progress.Value=100;close.Text="关闭";close.Visible=true;}
                    else if(code==2) {current=true;title.Text="当前已是最新版本";close.Visible=true;}
                    else {title.Text="更新未完成";now.Text="重试更新";now.Enabled=later.Enabled=true;close.Visible=true;}
                });
            });
        } catch(Exception error) {busy=false;title.Text="无法启动更新";detail.Text=error.Message;now.Enabled=later.Enabled=true;close.Visible=true;SyncSurface();}
    }
}
