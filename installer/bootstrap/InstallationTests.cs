using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;
using System.Windows.Forms;
using FaceSwapBootstrap;

public static class InstallationTests {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 };
    static readonly List<string> Keys = new List<string>();
    sealed class Quiet : IProgress<Status> { public void Report(Status status) { } }
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    static void Reject(Action action, string message) { bool rejected = false; try { action(); } catch { rejected = true; } Check(rejected, message); }
    static object Invoke(object control, string method, params object[] args) {
        return control.GetType().GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(control,args);
    }
    static void Put(string file, string text) { Directory.CreateDirectory(Path.GetDirectoryName(file)); File.WriteAllText(file, text); }
    static Manifest Manifest() { return new Manifest { appVersion = "2.0.2", entry = "启动FaceSwap Studio.exe", files = new[] { new Asset { name = "启动FaceSwap Studio.exe" }, new Asset { name = "faceswap studio/bridge/main.js" } } }; }
    static string Key() { string key = Installer.UninstallKey + ".Test." + Guid.NewGuid().ToString("N"); Keys.Add(key); return key; }
    static InstallState Begin(string root, string key) { var state = Installer.Begin(root, Manifest(), false, key); state.registryKey = key; Installer.SaveState(state); return state; }
    static string Report(string root, string session, bool ready = true) {
        string path = Path.Combine(root, "data/cache/install", session + ".json");
        Put(path, Json.Serialize(new { session = session, root = Installer.Canonical(root), ok = ready, status = ready ? "ready" : "error", error = "安装失败测试" })); return path;
    }
    static void ForeignShortcut(string file, string target) {
        object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")), link = null;
        try {
            link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { file });
            link.GetType().InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { target });
            link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
        } finally { if (link != null) Marshal.FinalReleaseComObject(link); Marshal.FinalReleaseComObject(shell); }
    }
    static void Junction(string link, string target) {
        var start = new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -Command \"New-Item -ItemType Junction -Path $env:FACESWAP_STUDIO_TEST_LINK -Target $env:FACESWAP_STUDIO_TEST_TARGET | Out-Null\"") { UseShellExecute = false, CreateNoWindow = true };
        start.EnvironmentVariables["FACESWAP_STUDIO_TEST_LINK"] = link; start.EnvironmentVariables["FACESWAP_STUDIO_TEST_TARGET"] = target;
        using (var child = Process.Start(start)) { child.WaitForExit(30000); Check(child.ExitCode == 0, "创建测试目录连接失败"); }
    }
    [STAThread] public static int Main() {
        string fixtureBase = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), "fixtures");
        string fixtures = Path.Combine(fixtureBase, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(fixtures);
        int passed = 0; Action<string, Action> test = (name, action) => { action(); passed++; Console.WriteLine("PASS " + name); };
        try {
            test("自绘按钮深浅主题及多尺寸圆角无白底，所有交互状态均正确合成", () => {
                string output=Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location),"button-rendering"); Directory.CreateDirectory(output);
                foreach(bool dark in new[] { false,true }) foreach(double scale in new[] { 1.0,1.25,1.5,2.0 }) {
                    Color paper=dark?Color.FromArgb(29,31,29):Color.FromArgb(251,250,247);
                    using(var form=new Form { ClientSize=new Size(600,230),BackColor=paper,ShowInTaskbar=false,Opacity=0 })
                    using(var button=new SoftButton { Text="重新检测",Dark=dark,BackColor=Color.White,Size=new Size((int)(120*scale),(int)(46*scale)),Location=new Point(20,20),Font=new Font("Microsoft YaHei UI",(float)(10*scale)) }) {
                        form.Controls.Add(button); form.Show(); Application.DoEvents();
                        foreach(string state in new[] { "normal","hover","pressed","disabled","focus" }) {
                            if(state=="hover") Invoke(button,"OnMouseEnter",EventArgs.Empty);
                            if(state=="pressed") Invoke(button,"OnMouseDown",new MouseEventArgs(MouseButtons.Left,1,10,10,0));
                            if(state=="disabled") button.Enabled=false;
                            if(state=="focus") { button.Enabled=true; button.Focus(); Invoke(button,"OnMouseLeave",EventArgs.Empty); }
                            using(var bitmap=new Bitmap(button.Width,button.Height)) {
                                button.DrawToBitmap(bitmap,button.ClientRectangle);
                                foreach(var point in new[] { new Point(0,0),new Point(bitmap.Width-1,0),new Point(0,bitmap.Height-1),new Point(bitmap.Width-1,bitmap.Height-1) }) {
                                    Color corner=bitmap.GetPixel(point.X,point.Y);
                                    Check(Math.Abs(corner.R-paper.R)<=1 && Math.Abs(corner.G-paper.G)<=1 && Math.Abs(corner.B-paper.B)<=1,"圆角外残留非父背景色："+state);
                                }
                                if(dark) for(int y=0;y<4;y++) for(int x=0;x<4;x++) Check(bitmap.GetPixel(x,y).R<100,"深色圆角出现白边");
                                else for(int y=0;y<3;y++) for(int x=0;x<3;x++) { var pixel=bitmap.GetPixel(x,y); Check(pixel.R<=paper.R+1 && pixel.G<=paper.G+1 && pixel.B<=paper.B+1,"浅色按钮采样边界出现亮边"); }
                                bitmap.Save(Path.Combine(output,(dark?"dark":"light")+"-"+(scale*100).ToString("0")+"-"+state+".png"),ImageFormat.Png);
                            }
                        }
                        form.Close();
                    }
                }
                // 捕获实际屏幕合成结果，补充 DrawToBitmap 无法覆盖的原生背景差异。
                foreach(bool dark in new[] { false,true }) using(var form=new Form { Text="FaceSwap 按钮渲染验收",ClientSize=new Size(380,140),BackColor=dark?Color.FromArgb(29,31,29):Color.FromArgb(251,250,247),StartPosition=FormStartPosition.CenterScreen,ShowInTaskbar=false,TopMost=true }) {
                    form.Controls.Add(new SoftButton { Dark=dark,Text="更改",Location=new Point(24,22),Size=new Size(80,35) });
                    form.Controls.Add(new SoftButton { Dark=dark,Text="重新检测",Location=new Point(126,22),Size=new Size(120,46) });
                    form.Controls.Add(new SoftButton { Dark=dark,Primary=true,Text="安装并运行",Location=new Point(126,84),Size=new Size(180,40) });
                    form.Controls.Add(new SoftButton { Dark=dark,Glyph=ButtonGlyph.Minimize,Text="−",Location=new Point(278,24),Size=new Size(28,28) });
                    form.Controls.Add(new SoftButton { Dark=dark,Glyph=ButtonGlyph.Close,Text="×",Location=new Point(318,24),Size=new Size(28,28) });
                    form.Show(); form.Refresh(); Application.DoEvents(); Thread.Sleep(160);
                    using(var bitmap=new Bitmap(form.ClientSize.Width,form.ClientSize.Height)) {
                        using(var graphics=Graphics.FromImage(bitmap)) graphics.CopyFromScreen(form.PointToScreen(Point.Empty),Point.Empty,form.ClientSize);
                        bitmap.Save(Path.Combine(output,"screen-"+(dark?"dark":"light")+".png"),ImageFormat.Png);
                    }
                    form.Close();
                }
            });
            test("自绘按钮保留 Enter/Escape/空格、禁用保护和辅助功能点击", () => {
                int accepts=0,cancels=0;
                using(var form=new Form { ShowInTaskbar=false,Opacity=0 }) {
                    var accept=new SoftButton { Text="安装",Size=new Size(120,40) };
                    var cancel=new SoftButton { Text="暂停",Location=new Point(130,0),Size=new Size(100,40) };
                    form.Controls.AddRange(new Control[] { accept,cancel }); form.AcceptButton=accept; form.CancelButton=cancel;
                    accept.Click+=(sender,args)=>accepts++; cancel.Click+=(sender,args)=>cancels++;
                    form.Show(); Application.DoEvents();
                    Invoke(form,"ProcessDialogKey",System.Windows.Forms.Keys.Enter); Invoke(form,"ProcessDialogKey",System.Windows.Forms.Keys.Escape);
                    Check(accepts==1 && cancels==1,"Enter/Escape 按钮契约丢失");
                    cancel.Focus(); Invoke(cancel,"OnKeyDown",new KeyEventArgs(System.Windows.Forms.Keys.Enter));
                    Check(cancels==2 && accepts==1,"焦点按钮的 Enter 错误触发默认安装按钮");
                    Invoke(accept,"OnKeyDown",new KeyEventArgs(System.Windows.Forms.Keys.Space)); Check(accepts==1,"按下空格时过早触发");
                    Invoke(accept,"OnKeyUp",new KeyEventArgs(System.Windows.Forms.Keys.Space)); Check(accepts==2,"释放空格未触发点击");
                    accept.AccessibilityObject.DoDefaultAction(); Check(accepts==3,"辅助功能不能点击");
                    accept.Enabled=false; accept.PerformClick(); accept.AccessibilityObject.DoDefaultAction(); Check(accepts==3,"禁用按钮仍然触发");
                    form.Close();
                }
            });
            test("切换开关保留选项值，关闭光效熄灭，动画可反向且禁用后不可切换", () => {
                using(var form=new Form { ShowInTaskbar=false,Opacity=0 }) {
                    var toggle=new GlowSwitch { Checked=true,Text="创建桌面快捷方式",Dark=true }; form.Controls.Add(toggle);
                    form.Show(); Application.DoEvents(); int changes=0; toggle.CheckedChanged+=(sender,args)=>changes++;
                    toggle.PerformClick(); Check(!toggle.Checked && toggle.IsAnimating,"关闭未启动贝塞尔动画");
                    toggle.AdvanceAnimation(.2); double intermediate=toggle.GlowStrength;
                    Check(intermediate>0 && intermediate<1,"光效没有逐渐熄灭");
                    toggle.PerformClick(); toggle.AdvanceAnimation(0); Check(Math.Abs(toggle.GlowStrength-intermediate)<.0001,"快速反向切换时动画跳变");
                    toggle.AdvanceAnimation(1); Check(toggle.Checked && toggle.GlowStrength==1,"开启光效未完成");
                    Invoke(toggle,"OnKeyDown",new KeyEventArgs(System.Windows.Forms.Keys.Space)); Invoke(toggle,"OnKeyUp",new KeyEventArgs(System.Windows.Forms.Keys.Space));
                    toggle.AdvanceAnimation(1); Check(!toggle.Checked && toggle.GlowStrength==0,"关闭后仍有光效");
                    toggle.AccessibilityObject.DoDefaultAction(); toggle.AdvanceAnimation(1);
                    Check(toggle.Checked && (toggle.AccessibilityObject.State&AccessibleStates.Checked)!=0,"辅助功能开关状态错误");
                    toggle.Enabled=false; toggle.PerformClick(); toggle.AccessibilityObject.DoDefaultAction(); Check(toggle.Checked && changes==4,"禁用开关仍触发");
                    form.Close();
                }
            });
            test("运行时长标题/文件名有独立文本区域，百分比、说明和进度不会重叠", () => {
                using(var bitmap=new Bitmap(720,830)) using(var g=Graphics.FromImage(bitmap)) {
                    string[] titles={ "正在补齐 Python 依赖与 CUDA 运行时，首次需要下载数 GB 文件", "正在下载 torch-2.7.1+cu128-cp312-cp312-win_amd64.whl",new String('长',150) };
                    foreach(string title in titles) {
                        var layout=PreparationTextLayout.Measure(g,title,false);
                        Check(layout.Title.Bottom<layout.Detail.Top && layout.Detail.Bottom<layout.Bar.Top && layout.Bar.Bottom<layout.Footnote.Top,"文本和进度区域重叠");
                        Check(layout.Title.Right<layout.Percent.Left && layout.Footnote.Bottom<412,"百分比重叠或状态卡越界");
                        if(title.Length<100) using(var font=new Font("Microsoft YaHei UI",layout.TitleSize,FontStyle.Bold,GraphicsUnit.Pixel))
                            Check(g.MeasureString(title,font,new SizeF(layout.Title.Width,10000)).Height<=layout.Title.Height,"典型长标题未适配字号");
                    }
                }
            });
            test("关闭/最小化矢量按钮在深浅主题和多尺寸下无白色圆角", () => {
                foreach(bool dark in new[] { false,true }) foreach(double scale in new[] { 1.0,1.25,1.5,2.0 }) foreach(ButtonGlyph glyph in new[] { ButtonGlyph.Close,ButtonGlyph.Minimize,ButtonGlyph.Sun,ButtonGlyph.Moon })
                using(var form=new Form { BackColor=dark?Color.FromArgb(29,31,29):Color.FromArgb(251,250,247),Opacity=0,ShowInTaskbar=false })
                using(var button=new SoftButton { Dark=dark,Glyph=glyph,BackColor=Color.White,Size=new Size((int)(28*scale),(int)(28*scale)) }) {
                    form.Controls.Add(button); form.Show(); Application.DoEvents();
                    using(var bitmap=new Bitmap(button.Width,button.Height)) {
                        button.DrawToBitmap(bitmap,button.ClientRectangle);
                        foreach(var p in new[] { new Point(0,0),new Point(bitmap.Width-1,0),new Point(0,bitmap.Height-1),new Point(bitmap.Width-1,bitmap.Height-1) }) {
                            Color pixel=bitmap.GetPixel(p.X,p.Y),paper=form.BackColor;
                            Check(pixel.A==255 && Math.Abs(pixel.R-paper.R)<=1 && Math.Abs(pixel.G-paper.G)<=1 && Math.Abs(pixel.B-paper.B)<=1,"标题栏按钮圆角残留主题白底："+dark+" / "+scale+" / "+glyph+" / "+pixel);
                        }
                        for(int y=0;y<4;y++) for(int x=0;x<4;x++) { var pixel=bitmap.GetPixel(x,y); Check(Math.Abs(pixel.R-form.BackColor.R)<=1 && Math.Abs(pixel.G-form.BackColor.G)<=1 && Math.Abs(pixel.B-form.BackColor.B)<=1,"标题栏按钮采样边界出现亮边"); }
                    }
                    form.Close();
                }
            });
            test("默认浅色，主题按钮同步全部控件并保留安装进度、目录、开关和滚动位置", () => {
                var drives=new[] { "C","D","E","F","G","H" }.Select(letter=>new InstallDrive { root=letter+@":\",ready=true,free=Installer.RequiredSpace*2 }).ToArray();
                using(var form=new Launcher(Manifest(),true,null,()=>@"D:\Program Files\FaceSwapStudio",()=>drives)) {
                    form.ShowInTaskbar=false; form.Opacity=0; form.Show(); Application.DoEvents();
                    Check(!form.IsDark && form.BackColor==Color.FromArgb(251,250,247),"默认没有使用浅色");
                    var theme=(SoftButton)form.Controls["theme"]; var panel=(DiskStrip)form.Controls["local-disks"];
                    var toggle=(GlowSwitch)form.Controls["desktop-shortcut"]; toggle.Checked=false; toggle.AdvanceAnimation(1); toggle.Enabled=false;
                    panel.ScrollToOffset(100,false);
                    form.SetPreview("working",.7); form.SetPreparationProgress(new Status { text="正在补齐 Python 依赖与 CUDA 运行时",done=70,total=100 },1);
                    string description=form.AccessibleDescription,root=form.Controls["destination"].Text;
                    theme.PerformClick();
                    Check(form.IsDark && form.BackColor==Color.FromArgb(29,31,29) && theme.Glyph==ButtonGlyph.Sun,"主题按钮没有切换深色");
                    Check(panel.BackColor==form.BackColor && panel.Controls.Cast<DiskCard>().All(card=>card.BackColor==form.BackColor),"磁盘列表没有同步主题");
                    Check(toggle.Dark && !toggle.Checked && !toggle.Enabled && panel.ScrollOffset==100,"主题切换改变了开关或滚动位置");
                    Check(form.AccessibleDescription==description && form.Controls["destination"].Text==root && !form.Controls["install"].Enabled,"主题切换重置安装状态");
                    theme.PerformClick(); Check(!form.IsDark && !toggle.Dark && theme.Glyph==ButtonGlyph.Moon,"主题无法切回浅色"); form.Close();
                }
            });
            test("自动选址优先非 C 盘 Program Files、容量排序及不可写目录避让", () => {
                var drives = new[] {
                    new InstallDrive { root = @"C:\", ready = true, free = Installer.RequiredSpace * 8 },
                    new InstallDrive { root = @"D:\", ready = true, free = Installer.RequiredSpace * 2 },
                    new InstallDrive { root = @"E:\", ready = true, free = Installer.RequiredSpace * 3 }
                };
                Check(Installer.SelectAutomaticRoot(drives, @"C:\Users\test\AppData\Local\Programs\FaceSwapStudio", p => true) == @"E:\Program Files\FaceSwapStudio", "没有选择空间最大的非 C 分区");
                Check(Installer.SelectAutomaticRoot(drives, @"C:\Users\test\AppData\Local\Programs\FaceSwapStudio", p => p.StartsWith(@"D:\")) == @"D:\Program Files\FaceSwapStudio", "未跳过不可写分区");
                var attempted = new List<string>();
                Reject(() => Installer.SelectAutomaticRoot(drives, @"C:\test", p => { attempted.Add(p); return false; }), "所有目录不可写却通过");
                Check(attempted.SequenceEqual(new[] { @"E:\Program Files\FaceSwapStudio", @"D:\Program Files\FaceSwapStudio", @"C:\test" }), "默认目录不可写时仍回退根目录或其他目录");
                Check(Installer.RootOnDrive(drives[2], drives, false) == @"E:\Program Files\FaceSwapStudio", "磁盘卡片与自动选址目录不一致");
            });
            test("其他分区不可用时回退可写 C 盘，手动选择也允许 C 盘", () => {
                var drives = new[] {
                    new InstallDrive { root = @"C:\", ready = true, free = Installer.RequiredSpace * 8 },
                    new InstallDrive { root = @"D:\", ready = true, free = Installer.RequiredSpace - 1 }
                };
                Check(Installer.SelectAutomaticRoot(drives, @"C:\用户\FaceSwapStudio", p => true) == @"C:\用户\FaceSwapStudio", "未回退可用的 C 盘");
                drives[1].ready = false;
                Check(Installer.SelectAutomaticRoot(drives, @"C:\用户\FaceSwapStudio", p => true) == @"C:\用户\FaceSwapStudio", "不可用分区阻止 C 盘安装");
                Installer.ValidateDestinationCapacity(@"C:\FaceSwapStudio", drives);
                Check(Installer.DriveProblem(drives[0], drives) == null, "C 盘卡片仍被禁用");
                Reject(() => Installer.ValidateDestinationCapacity(@"D:\Program Files\FaceSwapStudio", drives), "不可用分区通过");
            });
            test("C 盘多个候选逐个检查，拒绝跨盘路径并兼容中文", () => {
                var drives = new[] { new InstallDrive { root = @"C:\", ready = true, free = Installer.RequiredSpace * 2 } };
                string[] candidates = { @"D:\错盘", @"C:\Users\中文用户\AppData\Local\受限", @"C:\Users\中文用户\Apps\FaceSwapStudio" };
                var attempted = new List<string>();
                string chosen = Installer.SelectAutomaticRoot(drives, candidates, folder => { attempted.Add(folder); return folder == candidates[2]; });
                Check(chosen == candidates[2] && attempted.SequenceEqual(candidates.Skip(1)), "候选避让或中文路径选择失败");
                Check(Installer.SystemCandidates(@"C:\Users\中文用户\AppData\Local", @"C:\Users\中文用户")[0] == @"C:\Users\中文用户\AppData\Local\FaceSwapStudio", "C 盘仍默认 Programs 或未使用当前用户目录");
            });
            test("实际 EXE 创建/重命名检查和卸载器锁定检查，保留被占用文件", () => {
                string root = Path.Combine(fixtures, "中文权限检查");
                Check(Installer.ProbeWritable(root) && !Directory.Exists(root), "新目录 EXE 权限探测失败或残留");
                Begin(root, Key()); string file = Path.Combine(root, "uninstall.exe");
                File.Copy(Assembly.GetExecutingAssembly().Location, file);
                using (var held = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.None)) Check(!Installer.ProbeWritable(root), "被占用卸载器仍被判定可写");
                Check(Installer.ProbeWritable(root), "释放占用后仍不可写");
                File.SetAttributes(file, File.GetAttributes(file) | FileAttributes.ReadOnly);
                try { Check(!Installer.ProbeWritable(root), "只读卸载器仍通过权限检查"); }
                finally { File.SetAttributes(file, FileAttributes.Normal); }
            });
            test("卸载器原子更新、相同版本复用与写入失败保留原内容", () => {
                string root = Path.Combine(fixtures, "卸载器更新"), key = Key(); Begin(root, key);
                string source = Path.Combine(fixtures, "new-installer.exe"), target = Path.Combine(root, "uninstall.exe"); Put(source, "new installer bytes"); Put(target, "old bytes");
                Installer.InstallUninstaller(root, source); Check(File.ReadAllText(target) == "new installer bytes", "卸载器未更新");
                using (var held = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read)) Installer.InstallUninstaller(root, source);
                Put(source, "newer installer bytes");
                using (var held = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read)) Reject(() => Installer.InstallUninstaller(root, source), "锁定卸载器仍被覆盖");
                Check(File.ReadAllText(target) == "new installer bytes" && !Directory.GetFiles(root, ".uninstall-*.exe").Any(), "失败破坏旧卸载器或残留临时文件");
            });
            test("仅 C 盘时使用可写用户目录且严格检查容量阈值", () => {
                string root = @"C:\Users\test\AppData\Local\Programs\FaceSwapStudio";
                var drives = new[] { new InstallDrive { root = @"C:\", ready = true, free = Installer.RequiredSpace } };
                Check(Installer.SelectAutomaticRoot(drives, root, p => p == root) == root, "仅 C 盘选择错误");
                Installer.ValidateDestinationCapacity(root, drives);
                Reject(() => Installer.SelectAutomaticRoot(drives, root, p => false), "不可写用户目录通过");
                drives[0].free--; Reject(() => Installer.SelectAutomaticRoot(drives, root, p => true), "容量边界错误");
            });
            test("空间不足时安装界面仍可用，释放空间后重新检测恢复安装", () => {
                int attempts = 0;
                using (var form = new Launcher(Manifest(), false, false, () => {
                    if (++attempts == 1) throw new IOException("其他分区空间均不足。\n至少需要 12 GiB；D盘 1 GiB。请释放空间后重新检测。");
                    return @"G:\Program Files\FaceSwapStudio";
                })) {
                    form.ShowInTaskbar = false; form.Opacity = 0; form.Show(); Application.DoEvents();
                    var run = (SoftButton)form.Controls["install"]; var detect = (SoftButton)form.Controls["detect"];
                    Check(!run.Enabled && detect.Enabled && form.Controls["destination"].Text == "", "错误状态未阻止安装或不能重新检测");
                    Check(form.AccessibleDescription.Contains("空间均不足"), "没有显示不足原因");
                    detect.PerformClick(); Check(attempts == 2 && run.Enabled && form.Controls["destination"].Text == @"G:\Program Files\FaceSwapStudio", "重新检测未恢复");
                    form.Controls["destination"].Text = ""; Check(!run.Enabled, "空路径允许安装"); form.Close();
                }
            });
            test("磁盘卡片点击安装到专用文件夹，禁用分区不能被选中", () => {
                var drives = new[] {
                    new InstallDrive { root = @"C:\", ready = true, free = Installer.RequiredSpace * 8 },
                    new InstallDrive { root = @"D:\", ready = true, free = Installer.RequiredSpace * 2 },
                    new InstallDrive { root = @"E:\", ready = true, free = Installer.RequiredSpace * 3 },
                    new InstallDrive { root = @"G:\", ready = true, free = 100 }
                };
                using (var form = new Launcher(Manifest(), true, false, () => @"D:\Program Files\FaceSwapStudio", () => drives)) {
                    form.ShowInTaskbar = false; form.Opacity = 0; form.Show(); Application.DoEvents();
                    var panel = (DiskStrip)form.Controls["local-disks"];
                    var d = (DiskCard)panel.Controls["drive-D"]; var e = (DiskCard)panel.Controls["drive-E"];
                    var c = (DiskCard)panel.Controls["drive-C"]; var g = (DiskCard)panel.Controls["drive-G"];
                    Check(c.Enabled && !g.Enabled && d.Selected, "不可选磁盘状态错误");
                    Check(!panel.HasOverflow && !panel.VerticalScroll.Visible, "四张卡片产生了多余滚动条");
                    e.Choose(); Check(form.Controls["destination"].Text == @"E:\Program Files\FaceSwapStudio" && e.Selected && !d.Selected, "点击卡片未使用专用目录或选中状态未切换");
                    Check(e.IsAnimating, "选择未触发动画");
                    e.AdvanceAnimation(.25); double intermediate = e.IconScale;
                    Check(intermediate > 1 && intermediate < 1.17, "图标没有平滑放大");
                    e.AdvanceAnimation(1); Check(Math.Abs(e.IconScale-1.17)<.0001 && !e.IsAnimating, "缩放动画没有正确结束");
                    Check((e.AccessibilityObject.State & AccessibleStates.Checked) != 0, "辅助功能没有选中状态");
                    g.Choose(); Check(form.Controls["destination"].Text == @"E:\Program Files\FaceSwapStudio", "禁用分区仍可被选择");
                    c.Choose(); Check(Path.GetPathRoot(form.Controls["destination"].Text) == @"C:\" && c.Selected, "可用 C 盘未选择用户目录");
                    d.Choose(); e.AdvanceAnimation(1); Check(e.IconScale == 1, "切换后旧图标未恢复");
                    form.Close();
                }
            });
            test("所有贝塞尔缓动保持边界、连续单调，密集分区可横向浏览", () => {
                Check(BezierMotion.Ease(0) == 0 && BezierMotion.Ease(1) == 1, "缓动端点错误");
                double previous = 0;
                for (int i=1;i<=100;i++) { double value = BezierMotion.Ease(i/100.0); Check(value >= previous && value <= 1, "缓动越界或回跳"); previous=value; }
                var drives = new[] { "C", "D", "E", "F", "G", "H" }.Select(letter => new InstallDrive { root=letter+@":\", ready=true, free=Installer.RequiredSpace*2 }).ToArray();
                using (var form = new Launcher(Manifest(), true, false, () => @"D:\Program Files\FaceSwapStudio", () => drives)) {
                    form.ShowInTaskbar=false; form.Opacity=0; form.Show(); Application.DoEvents();
                    var panel=(DiskStrip)form.Controls["local-disks"];
                    Check(panel.Controls.Count==6 && panel.HasOverflow && !panel.VerticalScroll.Visible && !panel.HorizontalScroll.Visible, "出现了原生横/纵滚动条");
                    panel.ScrollToOffset(200); panel.AdvanceScrollAnimation(.3); Check(panel.ScrollOffset>0 && panel.ScrollOffset<200,"横向贝塞尔滚动未生效");
                    panel.AdvanceScrollAnimation(1); Check(panel.ScrollOffset==200 && panel.Controls[0].Left==-200,"横向偏移错误");
                    panel.ScrollToOffset(100000,false); Check(panel.Controls[5].Right==panel.ClientSize.Width,"末尾卡片不能完整显示或滚动越界");
                    panel.ScrollToOffset(-100,false); Check(panel.ScrollOffset==0,"横向滚动越过起点"); form.Close();
                }
            });
            test("禁止系统/个人根目录和非专用目录", () => {
                foreach (string path in new[] { Path.GetPathRoot(fixtures), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.GetFolderPath(Environment.SpecialFolder.Windows), Path.GetTempPath() }) Reject(() => Installer.ValidateRoot(path), "危险目录通过");
                string root = Path.Combine(fixtures, "foreign"); Put(Path.Combine(root, "user.txt"), "保留"); Reject(() => Begin(root, Key()), "已有用户文件被接管"); Check(File.ReadAllText(Path.Combine(root, "user.txt")) == "保留", "用户文件被改变");
            });
            test("安装目录独占锁及准备期间不登记应用", () => {
                string root = Path.Combine(fixtures, "lease"), key = Key();
                using (var lease = Installer.AcquireRoot(root)) {
                    var state = Installer.Begin(root, Manifest(), false, key, true);
                    Check(state.state == "preparing", "状态错误"); Reject(() => Installer.AcquireRoot(root), "并发安装未拦截");
                    using (var entry = Registry.CurrentUser.OpenSubKey(key)) Check(entry == null, "提前登记安装完成");
                }
            });
            test("组件选择复用原生动画开关，重新开启会清除移除意图", () => {
                string root=Path.Combine(fixtures,"component-picker");
                ComponentPicker.Save(root,new ComponentSelection { selected=new[] { "ace-xl-turbo" }, removed=new[] { "heartmula" } });
                var manifest=Manifest(); manifest.components=new[] {
                    new ComponentChoice { id="ace-xl-turbo",label="ACE-Step 1.5 XL Turbo",size=15000000000,minMemoryMB=15360 },
                    new ComponentChoice { id="heartmula",label="HeartMuLa 3B",size=22000000000,minMemoryMB=15360 }
                };
                using(var picker=new ComponentPicker(manifest,root,16384)) {
                    picker.Opacity=0; picker.ShowInTaskbar=false; picker.Show(); Application.DoEvents();
                    var ace=(GlowSwitch)picker.Controls["component-ace-xl-turbo"];
                    var heart=(GlowSwitch)picker.Controls["component-heartmula"];
                    Check(ace.Checked && !heart.Checked,"未保留现有选择");
                    Check(!picker.Controls.Cast<Control>().Any(c=>c is CheckedListBox),"仍有普通复选框列表");
                    heart.PerformClick(); heart.AdvanceAnimation(1);
                    ((SoftButton)picker.Controls["prepare-components"]).PerformClick();
                    Check(picker.Selection.selected.Contains("heartmula") && !picker.Selection.removed.Contains("heartmula"),"重新开启仍保留移除意图");
                }
            });
            test("组件初装预检拦截空间不足，已接管目录续装交给精确缺失量检查", () => {
                string root=Path.Combine(fixtures,"component-capacity"), key=Key();
                var manifest=Manifest(); manifest.components=new[] { new ComponentChoice { id="ace-xl-turbo", size=1024L*1024*1024*1024 } };
                var profile=new ComponentSelection { selected=new[] { "ace-xl-turbo" } };
                Reject(()=>ComponentPicker.ValidateCapacity(root,profile,manifest),"新安装未拦截空间不足");
                Begin(root,key);
                ComponentPicker.ValidateCapacity(root,profile,manifest);
            });
            test("新安装握手必须包含匹配所选组件的自检凭证", () => {
                string root=Path.Combine(fixtures,"components-ready"), session=Guid.NewGuid().ToString("N");
                var profile=new ComponentSelection { selected=new[] { "ace-xl-turbo" }, removed=new[] { "heartmula" } };
                ComponentPicker.Save(root,profile);
                string report=Report(root,session);
                Reject(() => Installer.RequireReady(root,report,session,true),"接受了只有基础环境的旧报告");
                string signature=new string('a',64);
                var receipt=new { protocol=2, selected=profile.selected, signature=signature };
                Put(Path.Combine(root,"data/cache/component-ready.json"),Json.Serialize(receipt));
                Put(report,Json.Serialize(new { session=session, root=root, ok=true, status="ready", components=receipt }));
                Installer.RequireReady(root,report,session,true);
                profile.selected=new[] { "yue2" }; ComponentPicker.Save(root,profile);
                Reject(() => Installer.RequireReady(root,report,session,true),"接受了过期选择的就绪报告");
            });
            test("必须取得正确会话的就绪报告才能创建快捷方式和注册", () => {
                string root = Path.Combine(fixtures, "not-ready"), key = Key(); Begin(root, key);
                Put(Path.Combine(root, "启动FaceSwap Studio.exe"), "app"); Put(Path.Combine(root, "uninstall.exe"), "uninstaller");
                var paths = new IntegrationPaths { desktop = Path.Combine(fixtures, "desktop-not-ready"), startMenu = Path.Combine(fixtures, "menu-not-ready"), registryKey = key };
                Reject(() => Installer.Complete(root, Manifest(), true, true, paths), "没有就绪报告却登记成功");
                string session = Guid.NewGuid().ToString("N"), report = Report(root, session);
                Reject(() => Installer.RequireReady(root, report, Guid.NewGuid().ToString("N")), "错误会话通过");
                Report(root, session, false); Reject(() => Installer.RequireReady(root, report, session), "失败报告通过");
                using (var entry = Registry.CurrentUser.OpenSubKey(key)) Check(entry == null, "失败后仍登记应用");
            });
            test("真实快捷方式/注册、保护同名快捷方式、卸载保留个人数据", () => {
                string root = Path.Combine(fixtures, "complete"), key = Key(); var state = Begin(root, key);
                Put(Path.Combine(root, "启动FaceSwap Studio.exe"), "app"); Put(Path.Combine(root, "uninstall.exe"), "uninstaller");
                Put(Path.Combine(root, "faceswap studio/bridge/main.js"), "app"); Put(Path.Combine(root, ".runtime/python.exe"), ".runtime"); Put(Path.Combine(root, ".assets/models/model.bin"), "model");
                Put(Path.Combine(root, "data/voices/voice.wav"), "personal"); Put(Path.Combine(root, "data/cache/download.part"), "cache");
                var paths = new IntegrationPaths { desktop = Path.Combine(fixtures, "desktop"), startMenu = Path.Combine(fixtures, "menu"), registryKey = key }; Directory.CreateDirectory(paths.desktop);
                string foreign = Path.Combine(paths.desktop, "FaceSwap Studio.lnk"), foreignTarget = Path.Combine(fixtures, "other.exe"); Put(foreignTarget, "other"); ForeignShortcut(foreign, foreignTarget);
                string session = Guid.NewGuid().ToString("N"), report = Report(root, session);
                Installer.Complete(root, Manifest(), true, true, paths, report, session); state = Installer.ReadState(root);
                Check(state.state == "complete" && state.shortcuts.Length == 3, "安装集成未完成");
                Check(Installer.ShortcutTarget(foreign) == foreignTarget, "覆盖了用户原有同名快捷方式");
                Check(state.shortcuts.Any(p => Path.GetFileName(p) == "FaceSwap Studio (2).lnk"), "没有避让同名快捷方式");
                using (var entry = Registry.CurrentUser.OpenSubKey(key)) { Check(Convert.ToString(entry.GetValue("InstallLocation")) == root, "注册位置错误"); Check(Convert.ToString(entry.GetValue("UninstallString")).Contains("uninstall.exe"), "卸载入口缺失"); }
                Installer.Remove(root, state.id, false);
                Check(File.Exists(Path.Combine(root, "data/voices/voice.wav")), "误删个人数据"); Check(!Directory.Exists(Path.Combine(root, ".assets/models")) && !Directory.Exists(Path.Combine(root, ".runtime")), "未清理依赖和模型");
                Check(!Directory.Exists(Path.Combine(root, "data/cache")), "未清理缓存"); Check(File.Exists(foreign), "误删用户同名快捷方式");
                Check(state.shortcuts.All(p => !File.Exists(p)), "自身快捷方式未删除");
                using (var entry = Registry.CurrentUser.OpenSubKey(key)) Check(entry == null, "应用列表入口未删除");
                string oldId = state.id; state = Begin(root, key); Check(state.id != oldId, "重装沿用已卸载标识"); Reject(() => Installer.Remove(root, oldId, true), "旧卸载会话能删除新安装");
            });
            test("默认卸载不穿越目录连接，可选清除也不删除外部目标", () => {
                string outside = Path.Combine(fixtures, "outside"); Put(Path.Combine(outside, "cache/keep.txt"), "outside");
                string root = Path.Combine(fixtures, "junction"), key = Key(); var state = Begin(root, key);
                Junction(Path.Combine(root, "faceswap studio"), outside); Junction(Path.Combine(root, "data"), outside);
                Installer.Remove(root, state.id, false); Check(File.Exists(Path.Combine(outside, "cache/keep.txt")), "默认卸载穿越了连接"); Check(Directory.Exists(Path.Combine(root, "data")), "默认卸载不应移除数据连接");
                state = Begin(root, key); Installer.Remove(root, state.id, true);
                Check(!Directory.Exists(Path.Combine(root, "data")), "未移除数据连接"); Check(File.Exists(Path.Combine(outside, "cache/keep.txt")), "删除了连接的外部目标");
            });
            test("卸载遇到占用文件时保留登记和卸载程序以便重试", () => {
                string root = Path.Combine(fixtures, "busy"), key = Key(); var state = Begin(root, key);
                Put(Path.Combine(root, "启动FaceSwap Studio.exe"), "app"); Put(Path.Combine(root, "uninstall.exe"), "uninstaller"); Put(Path.Combine(root, ".runtime/held.dll"), "locked");
                var paths = new IntegrationPaths { desktop = Path.Combine(fixtures, "busy-desktop"), startMenu = Path.Combine(fixtures, "busy-menu"), registryKey = key };
                string session = Guid.NewGuid().ToString("N"), report = Report(root, session); Installer.Complete(root, Manifest(), true, false, paths, report, session);
                using (var hold = new FileStream(Path.Combine(root, ".runtime/held.dll"), FileMode.Open, FileAccess.ReadWrite, FileShare.None)) {
                    Reject(() => Installer.Remove(root, state.id, false), "占用文件应使卸载暂停");
                    using (var entry = Registry.CurrentUser.OpenSubKey(key)) Check(entry != null, "失败后卸载入口丢失");
                    Check(File.Exists(Path.Combine(root, "uninstall.exe")), "失败后卸载程序丢失");
                }
                Installer.Remove(root, state.id, false);
                using (var entry = Registry.CurrentUser.OpenSubKey(key)) Check(entry == null, "重试卸载未完成");
            });
            test("可选清除个人数据及伪造归属/注册路径拒绝", () => {
                string root = Path.Combine(fixtures, "purge"), key = Key(); var state = Begin(root, key); Put(Path.Combine(root, "data/user.txt"), "personal");
                Reject(() => Installer.Remove(root, Guid.NewGuid().ToString("N"), true), "错误归属通过");
                state.registryKey = "Software"; Installer.SaveState(state); Reject(() => Installer.Remove(root, state.id, true), "危险注册表路径通过");
                Check(File.Exists(Path.Combine(root, "data/user.txt")), "拒绝后仍删除数据"); state.registryKey = key; Installer.SaveState(state); Installer.Remove(root, state.id, true); Check(!Directory.Exists(Path.Combine(root, "data")), "可选清除没有生效");
            });
            test("就绪等待支持成功、失败和取消", () => {
                string root = Path.Combine(fixtures, "report"), key = Key(); Begin(root, key); string session = Guid.NewGuid().ToString("N"), report = Report(root, session);
                Installer.WaitForReady(root, report, session, null, CancellationToken.None, new Quiet()).GetAwaiter().GetResult();
                Report(root, session, false); Reject(() => Installer.WaitForReady(root, report, session, null, CancellationToken.None, new Quiet()).GetAwaiter().GetResult(), "失败报告通过");
                File.Delete(report); var cancellation = new CancellationTokenSource(); cancellation.Cancel(); Reject(() => Installer.WaitForReady(root, report, session, null, cancellation.Token, new Quiet()).GetAwaiter().GetResult(), "取消未生效");
            });
            Console.WriteLine(passed + " installation integration tests passed"); return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally {
            foreach (string key in Keys) Registry.CurrentUser.DeleteSubKeyTree(key, false);
            if (Installer.SamePath(Path.GetDirectoryName(fixtures), fixtureBase) && System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(fixtures), @"^[a-f0-9]{32}$")) Installer.DeleteOwnedTree(fixtures);
        }
    }
}
