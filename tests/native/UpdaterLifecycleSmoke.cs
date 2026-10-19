using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
using FaceSwapBootstrap;

// 使用真实窗口和消息循环，执行器由 Python 测试提供，完全隔离正式安装。
internal static class UpdaterLifecycleSmoke {
    [STAThread] static int Main(string[] args) {
        if(args.Length>0 && args[0]=="--faceswap-run") {
            File.WriteAllText(Path.Combine(Path.GetDirectoryName(Application.ExecutablePath),"restored-studio"),
                Environment.GetEnvironmentVariable("FACESWAP_STUDIO_SKIP_UPDATE_PROMPT")+","+Environment.GetEnvironmentVariable("FACESWAP_STUDIO_SKIP_DEFERRED_UPDATE"));
            return 0;
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        string mode=args[0], session=args[1], python=args[2];
        int code=Int32.Parse(args[3]);
        StudioUpdateSurface window=mode=="legacy"
            ? (StudioUpdateSurface)new UpdateWindow(session,python)
            : new UpdateOfferWindow(session,python,mode=="startup");
        window.ShowInTaskbar=false;
        window.Opacity=0;
        bool checkedBusy=false, checkedFailure=false;
        string failure=null;
        var clock=Stopwatch.StartNew();
        var timer=new System.Windows.Forms.Timer{Interval=30};
        window.Shown+=(s,e)=>{
            if(mode=="now" || mode=="later")
                window.BeginInvoke((Action)(()=>{
                    if(mode=="later") window.SecondaryAction.PerformClick();
                    else window.PrimaryAction.PerformClick();
                }));
            timer.Start();
        };
        timer.Tick+=(s,e)=>{
            if(mode=="cancel" && clock.ElapsedMilliseconds>200) {window.Close();return;}
            if(clock.ElapsedMilliseconds>8000) {
                Console.Error.WriteLine("窗口未按预期结束："+window.StatusTitle);
                Environment.Exit(1);
            }
            if(!checkedBusy && window.Fraction==1 && !File.Exists(Path.Combine(session,"worker-finished"))) {
                window.Close();
                checkedBusy=!window.IsDisposed && window.Visible;
                if(!checkedBusy) failure="执行器尚未退出时窗口提前关闭";
            }
            string expected=code==2 && mode!="legacy"?"当前已是最新版本":"更新未完成";
            if(code!=0 && window.StatusTitle==expected && clock.ElapsedMilliseconds>1800) {
                checkedFailure=window.Visible && window.ReturnAction.Visible && window.ReturnAction.Enabled;
                if(mode!="legacy" && code==1)
                    checkedFailure=checkedFailure && window.PrimaryAction.Enabled && window.SecondaryAction.Enabled;
                window.Close();
            }
        };
        Application.Run(window);
        timer.Dispose();
        if(mode!="cancel" && !checkedBusy) failure="未确认更新中禁止关闭";
        if(mode!="cancel" && !File.Exists(Path.Combine(session,"worker-finished"))) failure="执行器尚未完成";
        if(code!=0 && !checkedFailure) failure="错误或无需更新状态未保留窗口与操作按钮";
        if(!window.IsDisposed) failure="窗口未释放";
        if(failure!=null) {Console.Error.WriteLine(failure);return 1;}
        Console.WriteLine("PASS "+mode+" exit="+code);
        return 0;
    }
}
