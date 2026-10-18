using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using System.Windows.Forms;

internal sealed class UpdateWindow : Form {
    readonly Label title = new Label(), detail = new Label();
    readonly ProgressBar progress = new ProgressBar();
    readonly Button close = new Button();
    Process child;
    bool complete;
    string session, python;
    public UpdateWindow(string directory, string interpreter) {
        session = directory; python = interpreter;
        Text = "FaceSwap Studio · 软件更新"; ClientSize = new Size(580, 255);
        StartPosition = FormStartPosition.CenterScreen; FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; BackColor = Color.FromArgb(250,250,250);
        Font = new Font("Microsoft YaHei UI", 10); Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        title.Text = "正在更新换脸工作台"; title.Font = new Font(Font.FontFamily, 18, FontStyle.Bold);
        title.SetBounds(28,28,520,40); detail.Text = "正在准备独立更新事务…"; detail.SetBounds(30,85,515,55);
        progress.SetBounds(30,150,520,9);
        close.Text = "关闭"; close.SetBounds(445,192,105,35); close.Enabled = false;
        close.Click += (s,e) => Close(); Controls.AddRange(new Control[]{title,detail,progress,close});
        FormClosing += (s,e) => { if (!complete) e.Cancel = true; };
        Shown += (s,e) => StartUpdate();
    }
    void Dispatch(Action action) { if (!IsDisposed && IsHandleCreated) BeginInvoke(action); }
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
        if(args.Length!=2 || !File.Exists(Path.Combine(args[0],"session.json")) || !File.Exists(args[1])) return 2;
        Application.Run(new UpdateWindow(Path.GetFullPath(args[0]),Path.GetFullPath(args[1]))); return 0;
    }
}
