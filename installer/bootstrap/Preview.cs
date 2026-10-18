using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using FaceSwapBootstrap;

public static class BootstrapPreview {
    [STAThread] public static int Main(string[] args) {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        var manifest = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 }.Deserialize<Manifest>(File.ReadAllText(args[0], Encoding.UTF8));
        string output = Path.GetFullPath(args[1]); Directory.CreateDirectory(output);
        if (manifest.components != null) foreach(bool darkMode in new[] { false,true }) using (var picker = new ComponentPicker(manifest, Path.Combine(output,"preview-selection"),16384,darkMode)) {
            picker.ShowInTaskbar=false; picker.Opacity=0; picker.Show(); Application.DoEvents(); picker.Update();
            using(var bitmap=new Bitmap(picker.Width,picker.Height)) {
                picker.DrawToBitmap(bitmap,new Rectangle(0,0,picker.Width,picker.Height));
                bitmap.Save(Path.Combine(output,darkMode?"component-selection-dark.png":"component-selection.png"),ImageFormat.Png);
            }
            picker.Close();
        }
        foreach (bool dark in new[] { false, true }) foreach (string state in new[] { "idle", "downloading", "paused", "ready", "disk-blocked", "disk-scroll", "runtime-long", "filename-long", "switch-off" }) {
            Func<string> detector = state == "disk-blocked" ? (Func<string>)(() => { throw new IOException("没有可用的安装分区。\n需要至少 12 GiB 可用空间；请释放空间或选择可写目录后重新检测。"); }) : null;
            Func<InstallDrive[]> survey = state == "disk-blocked" ? (Func<InstallDrive[]>)(() => new[] {
                new InstallDrive { root=@"C:\", ready=true, free=10L*1073741824 },
                new InstallDrive { root=@"D:\", ready=true, free=(long)(8.2*1073741824) },
                new InstallDrive { root=@"E:\", ready=true, free=(long)(3.6*1073741824) }
            }) : null;
            if(state=="disk-scroll") {
                detector=()=>@"D:\Program Files\FaceSwapStudio";
                survey=()=>new[] { "C","D","E","F","G","H" }.Select(letter=>new InstallDrive { root=letter+@":\",ready=true,free=Installer.RequiredSpace*3 }).ToArray();
            }
            using (var form = new Launcher(manifest, true, dark, detector, survey)) {
                form.ShowInTaskbar = false; form.Opacity = 0; form.Show(); Application.DoEvents();
                if (state != "disk-blocked") form.SetPreview(state=="disk-scroll"?"idle":state, state == "ready" ? 1 : state == "idle" || state=="disk-scroll" ? 0 : .42); form.Update();
                if(state=="runtime-long" || state=="filename-long") {
                    form.SetPreview("working",1);
                    form.SetPreparationProgress(new Status { text=state=="runtime-long"?"正在补齐 Python 依赖与 CUDA 运行时，首次需要下载数 GB 文件":"正在下载 torch-2.7.1+cu128-cp312-cp312-win_amd64.whl",done=1782579,total=1782579 },1);
                }
                if(state=="switch-off") {
                    form.SetPreview("idle",0);
                    foreach(var name in new[] { "desktop-shortcut","start-menu-shortcut" }) { var toggle=(GlowSwitch)form.Controls[name]; toggle.Checked=false; toggle.AdvanceAnimation(1); }
                }
                var panel = (DiskStrip)form.Controls["local-disks"];
                foreach (DiskCard card in panel.Controls) card.AdvanceAnimation(1);
                ((TextBox)form.Controls["destination"]).DeselectAll();
                using (var bitmap = new Bitmap(form.ClientSize.Width, form.ClientSize.Height)) {
                    form.DrawToBitmap(bitmap, form.ClientRectangle);
                    bitmap.Save(Path.Combine(output, state + (dark ? "-dark.png" : "-light.png")), ImageFormat.Png);
                }
                form.Close();
            }
        }
        using (var form = new Launcher(manifest, true, false)) {
            form.ShowInTaskbar=false; form.Opacity=0; form.Show(); Application.DoEvents();
            var panel=(DiskStrip)form.Controls["local-disks"];
            var cards=panel.Controls.Cast<DiskCard>().ToArray();
            var choices=cards.Where(card => card.Enabled).Take(3).ToArray();
            string frames=Path.Combine(output,"disk-animation-frames"); Directory.CreateDirectory(frames);
            int index=0;
            foreach (DiskCard card in cards) card.AdvanceAnimation(1);
            foreach (DiskCard choice in choices.Concat(choices.Take(1))) {
                choice.Choose();
                for (int frame=0;frame<=10;frame++) {
                    foreach (DiskCard card in cards) card.AdvanceAnimation(frame/10.0);
                    ((TextBox)form.Controls["destination"]).DeselectAll();
                    using (var bitmap=new Bitmap(form.ClientSize.Width,form.ClientSize.Height)) {
                        form.DrawToBitmap(bitmap,form.ClientRectangle);
                        using (var crop=bitmap.Clone(new Rectangle(30,232,660,255),PixelFormat.Format32bppArgb))
                            crop.Save(Path.Combine(frames,(index++).ToString("D3")+".png"),ImageFormat.Png);
                    }
                }
            }
            form.Close();
        }
        using(var form=new Launcher(manifest,true,true)) {
            form.ShowInTaskbar=false; form.Opacity=0; form.Show(); Application.DoEvents();
            var toggle=(GlowSwitch)form.Controls["desktop-shortcut"];
            string frames=Path.Combine(output,"switch-animation-frames"); Directory.CreateDirectory(frames); int index=0;
            foreach(bool on in new[] { false,true }) {
                toggle.Checked=on;
                for(int frame=0;frame<=12;frame++) {
                    toggle.AdvanceAnimation(frame/12.0);
                    using(var bitmap=new Bitmap(form.Width,form.Height)) {
                        form.DrawToBitmap(bitmap,form.ClientRectangle);
                        using(var crop=bitmap.Clone(new Rectangle(42,480,540,50),PixelFormat.Format32bppArgb)) crop.Save(Path.Combine(frames,(index++).ToString("D3")+".png"),ImageFormat.Png);
                    }
                }
            }
            form.Close();
        }
        foreach(bool dark in new[] { false,true }) using(var form=new Launcher(manifest,true,dark)) {
            form.ShowInTaskbar=false; form.TopMost=true; form.Show(); form.Refresh(); Application.DoEvents(); System.Threading.Thread.Sleep(180);
            using(var bitmap=new Bitmap(form.ClientSize.Width,form.ClientSize.Height)) {
                using(var graphics=Graphics.FromImage(bitmap)) graphics.CopyFromScreen(form.PointToScreen(Point.Empty),Point.Empty,form.ClientSize);
                bitmap.Save(Path.Combine(output,"screen-launcher-"+(dark?"dark":"light")+".png"),ImageFormat.Png);
            }
            form.Close();
        }
        Console.WriteLine("18 张实际原生界面及两张屏幕合成截图已渲染：" + output); return 0;
    }
}
