using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace FaceSwapBootstrap {
    public sealed class ComponentSelection {
        public int protocol = 1;
        public string[] selected = new string[0], removed = new string[0];
        public string defaultModel = "ace-xl-turbo";
    }
    public sealed class ComponentPicker : Form {
        public ComponentSelection Selection;
        readonly GlowSwitch[] switches;
        readonly Manifest manifest;
        readonly ComponentSelection previous;
        readonly bool dark;
        long selectedSize;
        int selectedCount;
        Bitmap brand;
        Color Paper { get { return dark ? Color.FromArgb(29,31,29) : Color.FromArgb(251,250,247); } }
        Color Ink { get { return dark ? Color.FromArgb(235,233,225) : Color.FromArgb(40,43,39); } }
        Color Muted { get { return dark ? Color.FromArgb(158,161,150) : Color.FromArgb(124,128,116); } }
        Color Accent { get { return dark ? Color.FromArgb(218,166,121) : Color.FromArgb(181,123,83); } }
        public static int GpuMemory() {
            try {
                var info = new ProcessStartInfo("nvidia-smi", "--query-gpu=memory.total --format=csv,noheader,nounits") { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true };
                using (var process = Process.Start(info)) {
                    if (!process.WaitForExit(5000)) { process.Kill(); return 0; }
                    int value; return Int32.TryParse(process.StandardOutput.ReadLine(), out value) ? value : 0;
                }
            } catch { return 0; }
        }
        public ComponentPicker(Manifest value, string root, int memory, bool darkMode=false) {
            manifest=value; dark=darkMode;
            string file = Path.Combine(root, "data", "component-selection.json");
            if (File.Exists(file)) previous = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 }.Deserialize<ComponentSelection>(File.ReadAllText(file));
            previous = previous ?? new ComponentSelection { selected = value.components.Where(c => (c.id == "lipsync" || c.id == "ace-xl-turbo") && memory >= c.minMemoryMB).Select(c => c.id).ToArray() };
            Text="易容 Studio · 选择功能"; ClientSize=new Size(720,830); Font=new Font("Microsoft YaHei UI",10);
            AutoScaleMode=AutoScaleMode.None; BackColor=Paper; DoubleBuffered=true;
            StartPosition=FormStartPosition.CenterParent; FormBorderStyle=FormBorderStyle.None; MaximizeBox=false; MinimizeBox=false;
            AccessibleName="选择安装功能与音乐模型";
            using (var shape=Launcher.Round(new RectangleF(0,0,720,830),22)) Region=new Region(shape);
            try { using(var stream=System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("app-mark.png"))
                if(stream!=null) using(var image=Image.FromStream(stream)) brand=new Bitmap(image); } catch { }
            switches=new GlowSwitch[value.components.Length];
            for(int i=0;i<switches.Length;i++) {
                var choice=value.components[i];
                var toggle=new GlowSwitch { Name="component-"+choice.id, Text="", Dark=dark, BackColor=Paper,
                    AccessibleName=choice.label, Checked=previous.selected.Contains(choice.id), TabIndex=i };
                toggle.SetBounds(602,261+i*78,64,46);
                toggle.CheckedChanged+=(s,e)=>UpdateEstimate(); switches[i]=toggle; Controls.Add(toggle);
            }
            var all = new SoftButton { Text="全部开启", Name="select-all", Left=566, Top=209, Width=112, Height=30, Dark=dark, BackColor=Paper };
            all.Click += (s,e) => { bool enable=switches.Any(toggle=>!toggle.Checked); foreach(var toggle in switches) toggle.Checked=enable; all.Text=enable?"全部关闭":"全部开启"; }; Controls.Add(all);
            var close = new SoftButton { Glyph=ButtonGlyph.Close, AccessibleName="返回安装器", Name="close", Left=666, Top=27, Width=28, Height=28, Dark=dark, BackColor=Paper, DialogResult=DialogResult.Cancel }; Controls.Add(close);
            var cancel = new SoftButton { Text="←  返回", Name="back", DialogResult=DialogResult.Cancel, Left=44, Top=744, Width=124, Height=48, Dark=dark, BackColor=Paper }; Controls.Add(cancel);
            var accept = new SoftButton { Text="准备并安装  →", Name="prepare-components", Left=456, Top=744, Width=222, Height=48, Primary=true, Dark=dark, BackColor=Paper };
            accept.Click += (s,e) => {
                string[] selected = switches.Select((toggle,i)=>new { toggle,i }).Where(x=>x.toggle.Checked).Select(x=>manifest.components[x.i].id).ToArray();
                Selection = new ComponentSelection { selected=selected, defaultModel=previous.defaultModel,
                    removed=previous.removed.Where(id => !selected.Contains(id)).ToArray() };
                DialogResult=DialogResult.OK; Close();
            }; Controls.Add(accept); AcceptButton=accept; CancelButton=cancel; UpdateEstimate();
        }
        void UpdateEstimate() {
            if(switches==null) return;
            var choices = switches.Select((toggle,i)=>new { toggle,i }).Where(x=>x.toggle!=null && x.toggle.Checked).Select(x=>manifest.components[x.i]).ToArray();
            selectedSize = choices.Sum(c => c.size) + (choices.Any(c => c.id != "lipsync") ? manifest.musicRuntimeSize : 0);
            selectedCount=choices.Length; Invalidate();
        }
        void TextAt(Graphics g,string text,float size,Color color,float x,float y,float width,bool bold=false) {
            using(var font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular,GraphicsUnit.Pixel))
            using(var brush=new SolidBrush(color))
                g.DrawString(text,font,brush,new RectangleF(x,y,width,size*2.5f));
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e); var g=e.Graphics; g.SmoothingMode=SmoothingMode.AntiAlias;
            using(var shape=Launcher.Round(new RectangleF(.5f,.5f,719,829),22))
            using(var border=new Pen(dark?Color.FromArgb(58,61,55):Color.FromArgb(224,225,216))) g.DrawPath(border,shape);
            if(brand!=null) g.DrawImage(brand,new Rectangle(44,35,26,26));
            TextAt(g,"FACESWAP_STUDIO  /  STUDIO",11,Muted,82,42,300);
            TextAt(g,"为创作，准备刚刚好。",29,Ink,42,86,620,true);
            TextAt(g,"选择需要的功能与模型，准备完成后进入工作区。",13,Muted,44,135,620);
            using(var shape=Launcher.Round(new RectangleF(44,173,634,34),10))
            using(var fill=new SolidBrush(dark?Color.FromArgb(38,41,36):Color.FromArgb(242,242,235))) g.FillPath(fill,shape);
            TextAt(g,"基础组件已包含",11,Ink,60,182,126,true);
            TextAt(g,"配音  ·  语音识别  ·  降噪",11,Muted,204,182,430);
            TextAt(g,"可选功能与音乐模型",11,Muted,44,220,400);
            for(int i=0;i<manifest.components.Length;i++) {
                var choice=manifest.components[i]; bool active=switches[i].Checked; float y=248+i*78;
                Color surface=active?(dark?Color.FromArgb(40,45,37):Color.FromArgb(243,244,235)):Paper;
                using(var shape=Launcher.Round(new RectangleF(44,y,634,70),14)) {
                    using(var fill=new SolidBrush(surface)) g.FillPath(fill,shape);
                    using(var pen=new Pen(active?(dark?Color.FromArgb(93,104,76):Color.FromArgb(190,201,167)):(dark?Color.FromArgb(58,61,55):Color.FromArgb(226,226,217)))) g.DrawPath(pen,shape);
                }
                switches[i].BackColor=surface;
                TextAt(g,choice.label,15,Ink,64,y+13,490,true);
                TextAt(g,(choice.size/Math.Pow(1024,3)).ToString("F2")+" GiB  ·  建议 "+(choice.minMemoryMB>=15360?16:8)+" GB 显存  ·  "+(choice.id=="ace-xl-turbo"?"默认主力":choice.id=="lipsync"?"视频创作":"可选音乐模型"),11,Muted,64,y+41,510);
            }
            using(var shape=Launcher.Round(new RectangleF(44,654,634,68),14))
            using(var fill=new SolidBrush(dark?Color.FromArgb(38,41,36):Color.FromArgb(242,242,235))) g.FillPath(fill,shape);
            TextAt(g,(selectedSize/Math.Pow(1024,3)).ToString("F1"),26,Ink,63,667,110,true);
            TextAt(g,"GiB",12,Muted,157,684,70);
            TextAt(g,"已选 "+selectedCount+" 项  ·  已有文件自动复用",12,Ink,246,668,407);
            TextAt(g,"另需基础组件与临时空间，可稍后移除或补齐模型。",10,Muted,246,693,407);
            TextAt(g,"国内源补齐  ·  已选组件全部就绪再进入",10,Muted,188,762,258);
        }
        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if(e.Button!=MouseButtons.Left) return;
            if(e.Y<75 && e.X<620) { ReleaseCapture(); SendMessage(Handle,0xA1,new IntPtr(2),IntPtr.Zero); return; }
            for(int i=0;i<switches.Length;i++) if(new Rectangle(44,248+i*78,554,70).Contains(e.Location)) { switches[i].Checked=!switches[i].Checked; return; }
        }
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ReleaseCapture();
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr handle,int message,IntPtr wparam,IntPtr lparam);
        protected override void Dispose(bool disposing) { if(disposing && brand!=null) brand.Dispose(); base.Dispose(disposing); }
        public static void Save(string root, ComponentSelection value) {
            string file=Path.Combine(root,"data","component-selection.json"); Directory.CreateDirectory(Path.GetDirectoryName(file));
            File.WriteAllText(file+".tmp",new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 }.Serialize(value),new System.Text.UTF8Encoding(false)); Core.ReplaceFile(file+".tmp",file);
        }
        public static void ValidateCapacity(string root, ComponentSelection selection, Manifest manifest) {
            // 续装交给Node按缺失文件和断点缓存计算，不能再次要求一整份初装空间。
            if(File.Exists(Path.Combine(root,Installer.Marker)) && Installer.ReadState(root).state!="uninstalled") return;
            long missing = 0;
            foreach (var component in manifest.components.Where(c => selection.selected.Contains(c.id))) {
                if (component.files == null) {
                    if (!File.Exists(Path.Combine(root,"data","lipsync","runtime.json")) && !File.Exists(Path.Combine(root,"data","lipsync","runtime-1.6.json"))) missing += component.size;
                    continue;
                }
                foreach (var asset in component.files) {
                    string target = Core.SafePath(root,asset.name);
                    if (!File.Exists(target) || new FileInfo(target).Length != asset.size) missing += Math.Max(0,asset.size-(File.Exists(target+".part")?new FileInfo(target+".part").Length:0));
                }
            }
            if (selection.selected.Any(id => id != "lipsync") && !File.Exists(Core.SafePath(root,"runtime/music/"+manifest.musicRuntimeVersion+"/ready.json")))
                missing += manifest.musicRuntimeSize + 2 * manifest.musicArchiveSize;
            bool existing = File.Exists(Path.Combine(root,Installer.Marker));
            long required = missing + (existing ? 1024L*1024*1024 : Installer.RequiredSpace);
            long free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(root))).AvailableFreeSpace;
            if (free < required) throw new IOException("所选功能空间不足：还需约 " + (required/Math.Pow(1024,3)).ToString("F1") + " GiB，可用 " + (free/Math.Pow(1024,3)).ToString("F1") + " GiB。请取消部分模型或更换安装分区。");
        }
    }
}
