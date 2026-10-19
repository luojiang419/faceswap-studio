using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]
[assembly: AssemblyTitle("易容 Studio 安装器")]
[assembly: AssemblyProduct("易容 Studio")]

namespace FaceSwapBootstrap {
    public sealed class Asset { public string name; public long size; public string sha256; public string[] urls; }
    public sealed class ComponentChoice { public string id, label; public long size; public int minMemoryMB; public Asset[] files; }
    public sealed class Manifest { public int protocol; public int componentProtocol; public ComponentChoice[] components; public long musicRuntimeSize, musicArchiveSize; public string musicRuntimeVersion; public string releaseId; public string appVersion; public string appReleaseId; public string publicKey; public string entry; public Asset package, application; public Asset[] files, baseFiles; public string[] applicationFiles; public string applicationEntry; }
    public sealed class Status { public string text; public long done; public long total; }

    public static class Core {
        static Core() {
            AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling", false);
            AppContext.SetSwitch("Switch.System.IO.BlockLongPaths", false);
        }
        public static string SafePath(string root, string relative) {
            if (String.IsNullOrEmpty(relative) || relative.Contains("\\") || relative.Contains(":")) throw new IOException("资源路径无效");
            foreach (string part in relative.Split('/'))
                if (part.Length == 0 || part == "." || part == ".." || part.TrimEnd(' ', '.') != part || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                    throw new IOException("资源路径无效：" + relative);
            string basePath = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string result = Path.GetFullPath(Path.Combine(basePath, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!result.StartsWith(basePath, StringComparison.OrdinalIgnoreCase)) throw new IOException("资源路径越界");
            return result;
        }
        public static string Hash(string file) {
            using (var stream = File.OpenRead(file)) using (var hash = SHA256.Create())
                return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        public static bool Verified(string file, Asset asset) {
            return File.Exists(file) && new FileInfo(file).Length == asset.size && Hash(file) == asset.sha256;
        }
        public static void Validate(Manifest manifest) {
            if (manifest.protocol != 1 || manifest.files == null || manifest.files.Length == 0 ||
                !System.Text.RegularExpressions.Regex.IsMatch(manifest.releaseId ?? "", @"^\d{14}$")) throw new IOException("启动器清单无效");
            SafePath(Path.GetTempPath(), manifest.entry);
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (Asset asset in manifest.files.Concat(new[] { manifest.package }).Concat(manifest.application==null?new Asset[0]:new[]{manifest.application}).Concat(manifest.baseFiles??new Asset[0])) {
                SafePath(Path.GetTempPath(), asset.name);
                if (asset.size < 0 || !System.Text.RegularExpressions.Regex.IsMatch(asset.sha256 ?? "", "^[a-f0-9]{64}$")) throw new IOException("清单校验信息无效");
            }
            foreach (Asset file in manifest.files) {
                if (!names.Add(file.name) || new[] { "data/", "models/", "runtime/" }.Any(p => file.name.StartsWith(p, StringComparison.OrdinalIgnoreCase)))
                    throw new IOException("桌面资源清单包含重复项或用户数据路径");
            }
            if (!names.Contains(manifest.entry) || manifest.package.urls == null || manifest.package.urls.Length == 0 ||
                manifest.package.urls.Any(u => new Uri(u).Scheme != "https")) throw new IOException("启动器下载地址无效");
            if(manifest.application!=null) {
                if(manifest.applicationFiles==null || manifest.applicationFiles.Length==0 ||
                    manifest.applicationFiles.Distinct(StringComparer.OrdinalIgnoreCase).Count()!=manifest.applicationFiles.Length ||
                    manifest.applicationFiles.Any(name=>!names.Contains(name) || name.StartsWith(".assets/",StringComparison.OrdinalIgnoreCase) || name.StartsWith(".venv-win/",StringComparison.OrdinalIgnoreCase) || name.StartsWith(".python/",StringComparison.OrdinalIgnoreCase) || name.StartsWith(".runtime/",StringComparison.OrdinalIgnoreCase)) ||
                    manifest.application.urls==null || manifest.application.urls.Length==0 || manifest.application.urls.Any(u=>new Uri(u).Scheme!="https") ||
                    manifest.application.name==manifest.package.name || (manifest.applicationEntry!="易容 Studio.exe" && manifest.applicationEntry!="启动FaceSwap Studio.exe"))
                    throw new IOException("独立应用包清单无效");
            }
        }
        public static string ApplicationSource(Manifest manifest,string name) {return name==manifest.entry?manifest.applicationEntry:name;}
        public static void ExtractApplication(string archive,string staging,Manifest manifest,CancellationToken token) {
            var expected=manifest.files.Where(f=>manifest.applicationFiles.Contains(f.name,StringComparer.OrdinalIgnoreCase)).ToDictionary(f=>ApplicationSource(manifest,f.name),StringComparer.OrdinalIgnoreCase);
            var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using(var zip=ZipFile.OpenRead(archive)) foreach(var entry in zip.Entries) {
                token.ThrowIfCancellationRequested();
                if(entry.FullName.EndsWith("/",StringComparison.Ordinal) && entry.Length==0) {
                    string directory=entry.FullName.TrimEnd('/');SafePath(staging,directory);
                    if(((entry.ExternalAttributes>>16)&0xf000)==0xa000 || !expected.Keys.Any(name=>name.StartsWith(directory+"/",StringComparison.OrdinalIgnoreCase))) throw new IOException("应用包目录无效");
                    continue;
                }
                SafePath(staging,entry.FullName);Asset asset;
                if(!expected.TryGetValue(entry.FullName,out asset) || !seen.Add(entry.FullName) || entry.Length!=asset.size || ((entry.ExternalAttributes>>16)&0xf000)==0xa000) throw new IOException("应用包文件与内置清单不一致");
                string target=SafePath(staging,asset.name);Directory.CreateDirectory(Path.GetDirectoryName(target));
                using(var input=entry.Open()) using(var output=File.Create(target)) {
                    byte[] buffer=new byte[256*1024];int count;long done=0;
                    while((count=input.Read(buffer,0,buffer.Length))>0) {
                        token.ThrowIfCancellationRequested();done+=count;
                        if(done>asset.size) throw new IOException("应用文件解压大小超过清单");
                        output.Write(buffer,0,count);
                    }
                }
                if(!Verified(target,asset)) throw new IOException("应用包文件 SHA-256 校验失败");
            }
            if(seen.Count!=expected.Count) throw new IOException("应用包缺少必要文件");
        }
        public static void Download(Asset asset, string directory, CancellationToken token, IProgress<Status> progress, bool allowHttp = false) {
            Directory.CreateDirectory(directory);
            string target = SafePath(directory, asset.name), part = target + ".part";
            token.ThrowIfCancellationRequested();
            if (Verified(target, asset)) return;
            if (Verified(part, asset)) { token.ThrowIfCancellationRequested(); ReplaceFile(part, target); return; }
            Exception last = null;
            foreach (string url in asset.urls) for (int attempt = 0; attempt < 2; attempt++) {
                token.ThrowIfCancellationRequested();
                long previousLength = File.Exists(part) ? new FileInfo(part).Length : 0;
                try {
                    if (new Uri(url).Scheme != "https" && !allowHttp) throw new IOException("下载地址必须使用 HTTPS");
                    long offset = File.Exists(part) ? new FileInfo(part).Length : 0;
                    if (offset >= asset.size) { File.Delete(part); offset = 0; }
                    var request = (HttpWebRequest)WebRequest.Create(url);
                    request.Timeout = 30000; request.ReadWriteTimeout = 60000; request.UserAgent = "Yirong-Studio-Bootstrap";
                    if (offset > 0) request.AddRange(offset);
                    using (token.Register(() => request.Abort()))
                    using (var response = (HttpWebResponse)request.GetResponse()) {
                        long responseSize = asset.size - offset;
                        if (response.StatusCode == HttpStatusCode.PartialContent) {
                            var range = System.Text.RegularExpressions.Regex.Match(response.Headers["Content-Range"] ?? "", @"^bytes (\d+)-(\d+)/(\d+)$");
                            if (!range.Success || Int64.Parse(range.Groups[1].Value) != offset || Int64.Parse(range.Groups[3].Value) != asset.size ||
                                Int64.Parse(range.Groups[2].Value) < offset || Int64.Parse(range.Groups[2].Value) >= asset.size)
                                throw new IOException("服务器续传范围与清单不一致");
                            responseSize = Int64.Parse(range.Groups[2].Value) - offset + 1;
                        } else if (response.StatusCode == HttpStatusCode.OK) { offset = 0; responseSize = asset.size; }
                        else throw new IOException("下载返回 HTTP " + (int)response.StatusCode);
                        if (response.ContentLength >= 0 && response.ContentLength != responseSize) throw new IOException("下载大小与清单不一致");
                        using (var input = response.GetResponseStream())
                        using (var output = new FileStream(part, offset > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read)) {
                            byte[] buffer = new byte[256 * 1024]; long done = offset; int count;
                            var timer = Stopwatch.StartNew();
                            while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                                token.ThrowIfCancellationRequested(); done += count;
                                if (done > asset.size) throw new IOException("下载超过清单大小限制");
                                output.Write(buffer, 0, count);
                                if (timer.ElapsedMilliseconds >= 150) { progress.Report(new Status { text = "正在从魔搭补齐桌面环境", done = done, total = asset.size }); timer.Restart(); }
                            }
                            output.Flush(true);
                        }
                    }
                    token.ThrowIfCancellationRequested();
                    if (!Verified(part, asset)) {
                        if (File.Exists(part) && new FileInfo(part).Length >= asset.size) File.Delete(part);
                        throw new IOException("下载不完整或 SHA-256 校验失败，可继续重试");
                    }
                    ReplaceFile(part, target); return;
                } catch (Exception error) {
                    token.ThrowIfCancellationRequested(); last = error;
                    if (File.Exists(part) && new FileInfo(part).Length > previousLength && new FileInfo(part).Length < asset.size) attempt = -1;
                }
            }
            throw new IOException("魔搭资源下载未完成，已保留下载分片。" + (last == null ? "" : last.Message), last);
        }
        public static void ReplaceFile(string source, string target) {
            if (File.Exists(target)) File.Replace(source, target, null); else File.Move(source, target);
        }
        public static bool DesktopReady(string root, Manifest manifest, CancellationToken token) {
            // 应用自身通过签名更新器升级；原生启动器不能用旧内置包覆盖已经安装的新版。
            string configPath = SafePath(root, "update-config.json");
            string versionPath = SafePath(root, "VERSION");
            if (!String.IsNullOrEmpty(manifest.appReleaseId) && File.Exists(configPath) && File.Exists(versionPath)) {
                var config = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 }.Deserialize<Dictionary<string, object>>(File.ReadAllText(configPath));
                Version current, original;
                if (Version.TryParse(File.ReadAllText(versionPath).Trim(), out current) && Version.TryParse(manifest.appVersion, out original) &&
                    current >= original && config.ContainsKey("releaseId") && String.CompareOrdinal(Convert.ToString(config["releaseId"]), manifest.appReleaseId) > 0) {
                    Asset executable = manifest.files.First(a => a.name == manifest.entry);
                    if (!Verified(SafePath(root, manifest.entry), executable)) throw new IOException("启动器已变更，请使用新版安装器修复；保留当前版本。");
                    foreach (string name in new[] { manifest.entry, "updater/transaction.py", "faceswap studio/bridge/app_server.py", "faceswap studio/runtime/windows_app/current/faceswap_studio.exe" })
                        if (!File.Exists(SafePath(root, name))) throw new IOException("新版工作台文件不完整，请使用更新恢复；保留当前版本。");
                    return true;
                }
            }
            foreach (Asset file in manifest.files) { token.ThrowIfCancellationRequested(); if (!Verified(SafePath(root, file.name), file)) return false; }
            return true;
        }
        public static void Extract(string archive, string staging, Manifest manifest, CancellationToken token,bool allowUnused=false) {
            var expected = manifest.files.ToDictionary(a => a.name, StringComparer.OrdinalIgnoreCase);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var zip = ZipFile.OpenRead(archive)) {
                foreach (var entry in zip.Entries) {
                    token.ThrowIfCancellationRequested();
                    int slash = entry.FullName.IndexOf('/');
                    // ZIP 工具可能显式记录目录；只接受签名文件清单所需的父目录。
                    if (entry.FullName.EndsWith("/", StringComparison.Ordinal) && entry.Length == 0 && slash > 0) {
                        if ((((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000)) throw new IOException("压缩包包含目录链接");
                        if (slash == entry.FullName.Length - 1) continue;
                        string folder = entry.FullName.Substring(slash + 1).TrimEnd('/');
                        SafePath(staging, folder);
                        if (!allowUnused && !expected.Keys.Any(name => name.StartsWith(folder + "/", StringComparison.OrdinalIgnoreCase)))
                            throw new IOException("压缩包包含清单以外的目录");
                        continue;
                    }
                    if (slash <= 0 || slash == entry.FullName.Length - 1) throw new IOException("桌面压缩包条目无效");
                    string relative = entry.FullName.Substring(slash + 1);
                    string target = SafePath(staging, relative);
                    Asset asset;
                    if(allowUnused && !expected.ContainsKey(relative)) {
                        if(((entry.ExternalAttributes>>16)&0xf000)==0xa000) throw new IOException("基础包包含文件链接");
                        continue;
                    }
                    if (!expected.TryGetValue(relative, out asset) || !seen.Add(relative) || entry.Length != asset.size ||
                        (((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000)) throw new IOException("压缩包文件与内置清单不一致");
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (var input = entry.Open()) using (var output = File.Create(target)) {
                        byte[] buffer = new byte[256 * 1024]; int count; long done = 0;
                        while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                            token.ThrowIfCancellationRequested(); done += count;
                            if (done > asset.size) throw new IOException("解压大小超过清单");
                            output.Write(buffer, 0, count);
                        }
                    }
                    if (!Verified(target, asset)) throw new IOException("解压文件 SHA-256 校验失败");
                }
            }
            if (seen.Count != expected.Count) throw new IOException("桌面压缩包缺少必要文件");
        }
        public static string Prepare(string root, Manifest manifest, CancellationToken token, IProgress<Status> progress) {
            Validate(manifest); Directory.CreateDirectory(root);
            progress.Report(new Status { text = "正在校验桌面环境" });
            if (!DesktopReady(root, manifest, token)) {
                string executable = SafePath(root, manifest.entry);
                foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(manifest.entry))) {
                    try { if (String.Equals(process.MainModule.FileName, executable, StringComparison.OrdinalIgnoreCase)) throw new IOException("请先关闭工作台，再恢复桌面环境。"); }
                    catch (System.ComponentModel.Win32Exception) { }
                    finally { process.Dispose(); }
                }
                string cache = Path.Combine(root, "data", "cache", "bootstrap");
                Download(manifest.package, cache, token, progress);
                if(manifest.application!=null) Download(manifest.application,cache,token,progress);
                string staging = Path.Combine(root, ".desktop-staging-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(staging);
                try {
                    progress.Report(new Status { text = "正在校验并展开桌面环境" });
                    Extract(SafePath(cache, manifest.package.name), staging, manifest.application==null?manifest:new Manifest{files=manifest.files.Where(f=>!manifest.applicationFiles.Contains(f.name,StringComparer.OrdinalIgnoreCase)).ToArray()}, token,manifest.application!=null);
                    if(manifest.application!=null) ExtractApplication(SafePath(cache,manifest.application.name),staging,manifest,token);
                    foreach (Asset file in manifest.files) {
                        token.ThrowIfCancellationRequested();
                        string target = SafePath(root, file.name); Directory.CreateDirectory(Path.GetDirectoryName(target));
                        ReplaceFile(SafePath(staging, file.name), target);
                    }
                } finally {
                    // 仅删除本次创建、位于安装目录内的解压暂存目录。
                    if (Path.GetDirectoryName(staging) == Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) &&
                        Path.GetFileName(staging).StartsWith(".desktop-staging-", StringComparison.Ordinal) && Directory.Exists(staging)) Directory.Delete(staging, true);
                }
                if (!DesktopReady(root, manifest, token)) throw new IOException("桌面环境复检失败，请重试");
            }
            token.ThrowIfCancellationRequested();
            return SafePath(root, manifest.entry);
        }
    }

    public enum ButtonGlyph { None, Close, Minimize, Sun, Moon }
    public sealed class SoftButton : Control, IButtonControl {
        public bool Primary, Dark;
        public ButtonGlyph Glyph;
        bool hovering, pressed;
        Bitmap background;
        Color cachedSurface, cachedPaper, cachedInk;
        ButtonGlyph cachedGlyph;
        public DialogResult DialogResult { get; set; }
        public SoftButton() {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable | ControlStyles.StandardClick, true);
            Cursor = Cursors.Hand; TabStop = true; AccessibleRole = AccessibleRole.PushButton;
            Font = new Font("Microsoft YaHei UI", 10);
        }
        public void NotifyDefault(bool value) { Invalidate(); }
        public void PerformClick() { if (CanSelect) OnClick(EventArgs.Empty); }
        protected override AccessibleObject CreateAccessibilityInstance() { return new ButtonAccessibility(this); }
        sealed class ButtonAccessibility : ControlAccessibleObject {
            readonly SoftButton button;
            public ButtonAccessibility(SoftButton value) : base(value) { button=value; }
            public override string DefaultAction { get { return "点击"; } }
            public override void DoDefaultAction() { button.PerformClick(); }
        }
        protected override void OnClick(EventArgs e) {
            if (!Enabled) return;
            if (DialogResult != DialogResult.None && FindForm() != null) FindForm().DialogResult = DialogResult;
            base.OnClick(e);
        }
        protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovering = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (Enabled && e.Button == MouseButtons.Left) { pressed = true; Focus(); Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnMouseCaptureChanged(EventArgs e) { pressed = false; Invalidate(); base.OnMouseCaptureChanged(e); }
        protected override void OnEnabledChanged(EventArgs e) { pressed = false; Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { pressed = false; Invalidate(); base.OnLostFocus(e); }
        protected override bool IsInputKey(Keys keyData) { return (keyData & Keys.KeyCode) == Keys.Space || (keyData & Keys.KeyCode) == Keys.Enter || base.IsInputKey(keyData); }
        protected override void OnKeyDown(KeyEventArgs e) {
            if (e.KeyCode == Keys.Space && Enabled) { pressed = true; Invalidate(); e.Handled = true; }
            if (e.KeyCode == Keys.Enter && Enabled) { PerformClick(); e.Handled = true; e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
        }
        protected override void OnKeyUp(KeyEventArgs e) { if (e.KeyCode == Keys.Space && pressed) { pressed = false; PerformClick(); Invalidate(); e.Handled = true; } base.OnKeyUp(e); }
        protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(Parent == null ? BackColor : Parent.BackColor); }
        void CacheBackground(Color paper, Color surface, Color ink) {
            if (background != null && background.Size == ClientSize && cachedPaper == paper && cachedSurface == surface && cachedInk == ink && cachedGlyph == Glyph) return;
            if (background != null) background.Dispose();
            background = new Bitmap(Width, Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            // 圆角先以 4 倍尺寸绘制再缩小，并用父背景预合成，避免原生主题白底和透明边缘白色杂边。
            using (var large = new Bitmap(Width * 4, Height * 4, System.Drawing.Imaging.PixelFormat.Format32bppPArgb)) {
                using (var g = Graphics.FromImage(large)) {
                    g.Clear(paper); g.ScaleTransform(4,4); g.SmoothingMode = SmoothingMode.AntiAlias;
                    float radius=Glyph==ButtonGlyph.None?Math.Min(12,Height*.27f):Math.Min(Width,Height)/2f-.5f;
                    using (var shape = Launcher.Round(new RectangleF(.5f,.5f,Width-1,Height-1),radius))
                    using (var fill = new SolidBrush(surface)) g.FillPath(fill,shape);
                    if(Glyph!=ButtonGlyph.None) {
                        float scale=Math.Min(Width,Height)/28f, cx=Width/2f, cy=Height/2f, r=3.5f*scale;
                        using(var pen=new Pen(ink,1.35f*scale) { StartCap=LineCap.Round,EndCap=LineCap.Round }) {
                            if(Glyph==ButtonGlyph.Close) { g.DrawLine(pen,cx-r,cy-r,cx+r,cy+r); g.DrawLine(pen,cx+r,cy-r,cx-r,cy+r); }
                            else if(Glyph==ButtonGlyph.Minimize) g.DrawLine(pen,cx-r,cy,cx+r,cy);
                            else if(Glyph==ButtonGlyph.Sun) {
                                g.DrawEllipse(pen,cx-2.5f*scale,cy-2.5f*scale,5*scale,5*scale);
                                for(int i=0;i<8;i++) { double angle=i*Math.PI/4; g.DrawLine(pen,cx+(float)Math.Cos(angle)*4.5f*scale,cy+(float)Math.Sin(angle)*4.5f*scale,cx+(float)Math.Cos(angle)*6.2f*scale,cy+(float)Math.Sin(angle)*6.2f*scale); }
                            } else {
                                using(var fill=new SolidBrush(ink)) g.FillEllipse(fill,cx-4.7f*scale,cy-4.7f*scale,9.4f*scale,9.4f*scale);
                                using(var cutout=new SolidBrush(surface)) g.FillEllipse(cutout,cx-1.9f*scale,cy-6.2f*scale,8.8f*scale,8.8f*scale);
                            }
                        }
                    }
                }
                using (var g = Graphics.FromImage(background)) {
                    g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    // 镜像边界避免双三次采样读到图片外的透明黑，造成浅色背景亮边。
                    using(var attributes=new System.Drawing.Imaging.ImageAttributes()) {
                        attributes.SetWrapMode(WrapMode.TileFlipXY);
                        g.DrawImage(large,new Rectangle(0,0,Width,Height),0,0,large.Width,large.Height,GraphicsUnit.Pixel,attributes);
                    }
                }
            }
            cachedPaper=paper; cachedSurface=surface; cachedInk=ink; cachedGlyph=Glyph;
        }
        protected override void OnPaint(PaintEventArgs e) {
            if (Width < 2 || Height < 2) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color surface = Primary ? (Dark ? Color.FromArgb(236, 232, 224) : Color.FromArgb(40, 42, 39)) : (Dark ? Color.FromArgb(43, 44, 41) : Color.FromArgb(242, 241, 236));
            if (hovering && Enabled) surface = Primary ? (Dark ? Color.White : Color.FromArgb(66, 67, 61)) : (Dark ? Color.FromArgb(55, 56, 51) : Color.FromArgb(233, 231, 224));
            if (pressed && Enabled) surface = Primary ? (Dark ? Color.FromArgb(218,214,205) : Color.FromArgb(27,30,26)) : (Dark ? Color.FromArgb(65,69,59) : Color.FromArgb(221,225,211));
            Color ink = Primary ? (Dark ? Color.FromArgb(35, 36, 33) : Color.White) : (Dark ? Color.FromArgb(217, 216, 207) : Color.FromArgb(83, 85, 78));
            if (!Enabled) ink = Color.FromArgb(146, 146, 136);
            CacheBackground(Parent == null ? BackColor : Parent.BackColor,surface,ink);
            e.Graphics.DrawImageUnscaled(background,0,0);
            if(Glyph==ButtonGlyph.None) TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ink, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            if (Focused && ShowFocusCues) using(var pen=new Pen(Dark?Color.FromArgb(190,157,114):Color.FromArgb(147,120,82)) { DashStyle=DashStyle.Dot })
                using(var path=Launcher.Round(new RectangleF(4,4,Width-9,Height-9),8)) e.Graphics.DrawPath(pen,path);
        }
        protected override void Dispose(bool disposing) { if(disposing && background!=null) background.Dispose(); base.Dispose(disposing); }
    }

    // 原创人脸配准插画：轮廓、稀疏特征网与沿映射曲线移动的粒子。
    // 使用原生向量，随主题与 DPI 缩放，不依赖位图帧或网页运行时。
    public static class FaceFusionArtwork {
        static readonly PointF[] Landmarks = {
            new PointF(-25,-27), new PointF(25,-27), new PointF(-28,-7), new PointF(28,-7),
            new PointF(-22,18), new PointF(22,18), new PointF(-13,36), new PointF(13,36), new PointF(0,44),
            new PointF(-20,-14), new PointF(-10,-15), new PointF(10,-15), new PointF(20,-14),
            new PointF(0,-8), new PointF(-6,10), new PointF(6,10),
            new PointF(-12,25), new PointF(0,22), new PointF(12,25), new PointF(0,30)
        };
        static readonly int[,] Edges = {
            {0,9},{0,10},{1,11},{1,12},{2,9},{2,14},{3,12},{3,15},{9,10},{11,12},
            {10,13},{11,13},{13,14},{13,15},{14,15},{14,16},{15,18},{14,17},{15,17},
            {4,14},{5,15},{4,16},{5,18},{16,17},{17,18},{16,19},{18,19},{6,19},{7,19},{8,19}
        };
        static GraphicsPath Contour() {
            var path = new GraphicsPath();
            path.AddBezier(-29,-18,-32,-57,32,-57,29,-18);
            path.AddBezier(29,-18,32,-8,29,0,27,3);
            path.AddBezier(27,3,25,25,15,42,0,46);
            path.AddBezier(0,46,-15,42,-25,25,-27,3);
            path.AddBezier(-27,3,-29,0,-32,-8,-29,-18); path.CloseFigure(); return path;
        }
        static PointF Curve(float t, PointF a, PointF b, PointF c, PointF d) {
            float u=1-t;
            return new PointF(u*u*u*a.X+3*u*u*t*b.X+3*u*t*t*c.X+t*t*t*d.X,
                              u*u*u*a.Y+3*u*u*t*b.Y+3*u*t*t*c.Y+t*t*t*d.Y);
        }
        static void Face(Graphics g,float x,float y,float scale,Color ink,Color paper,double time,bool scan) {
            var state=g.Save(); g.TranslateTransform(x,y); g.ScaleTransform(scale,scale);
            using(var contour=Contour()) {
                using(var fill=new SolidBrush(paper)) g.FillPath(fill,contour);
                using(var pen=new Pen(Color.FromArgb(175,ink),1.25f)) g.DrawPath(pen,contour);
                using(var pen=new Pen(Color.FromArgb(53,ink),.75f))
                    for(int i=0;i<Edges.GetLength(0);i++) g.DrawLine(pen,Landmarks[Edges[i,0]],Landmarks[Edges[i,1]]);
                // 眉眼、鼻梁和嘴唇使小尺寸下依然能直接读出“人脸”。
                using(var pen=new Pen(Color.FromArgb(175,ink),1.15f) { StartCap=LineCap.Round,EndCap=LineCap.Round }) {
                    g.DrawBezier(pen,-21,-21,-17,-25,-12,-25,-8,-22);
                    g.DrawBezier(pen,8,-22,12,-25,17,-25,21,-21);
                    g.DrawBezier(pen,-20,-14,-17,-11,-13,-11,-10,-15);
                    g.DrawBezier(pen,10,-15,13,-11,17,-11,20,-14);
                    g.DrawLines(pen,new[] {new PointF(0,-8),new PointF(-4,9),new PointF(0,12),new PointF(5,9)});
                    g.DrawBezier(pen,-12,25,-4,29,4,29,12,25);
                }
                if(scan) {
                    var clip=g.Save(); g.SetClip(contour);
                    float line=(float)(-44+90*((Math.Sin(time*.9)+1)/2));
                    using(var fade=new LinearGradientBrush(new PointF(0,line-15),new PointF(0,line),Color.FromArgb(0,ink),Color.FromArgb(28,ink)))
                        g.FillRectangle(fade,-33,line-15,66,15);
                    using(var pen=new Pen(Color.FromArgb(115,ink),.9f)) g.DrawLine(pen,-33,line,33,line);
                    g.Restore(clip);
                }
                for(int i=0;i<Landmarks.Length;i++) {
                    float radius=i>=9?1.5f:1.2f;
                    using(var brush=new SolidBrush(Color.FromArgb(i>=9?210:145,ink)))
                        g.FillEllipse(brush,Landmarks[i].X-radius,Landmarks[i].Y-radius,radius*2,radius*2);
                }
            }
            g.Restore(state);
        }
        public static void Draw(Graphics g,bool dark,double seconds,string view) {
            var state=g.Save(); g.SetClip(new RectangleF(438,103,244,140));
            Color copper=dark?Color.FromArgb(218,166,121):Color.FromArgb(169,109,72);
            Color sage=dark?Color.FromArgb(151,164,144):Color.FromArgb(137,151,128);
            Color paper=dark?Color.FromArgb(29,31,29):Color.FromArgb(251,250,247);
            bool moving=view=="idle" || view=="downloading" || view=="working";
            double time=seconds;
            using(var pen=new Pen(Color.FromArgb(dark?34:40,copper),.8f)) {
                g.DrawEllipse(pen,554,110,116,116);
                g.DrawArc(pen,546,102,132,132,215,75);
            }
            float breathe=moving?(float)Math.Sin(time*.8)*1.1f:0;
            Face(g,490,168+breathe,.88f,sage,paper,time,false);
            // 三条对应关系穿过两张人脸之间，粒子向目标脸移动。
            for(int i=0;i<3;i++) {
                float y=149+i*22;
                var a=new PointF(516,y); var b=new PointF(541,y-19+i*9);
                var c=new PointF(553,y+19-i*9); var d=new PointF(582,y);
                using(var pen=new Pen(Color.FromArgb(dark?64:70,copper),.85f)) g.DrawBezier(pen,a,b,c,d);
                if(moving) {
                    float t=(float)((time*.23+i*.31)%1); var p=Curve(t,a,b,c,d);
                    using(var brush=new SolidBrush(Color.FromArgb(28,copper))) g.FillEllipse(brush,p.X-5,p.Y-5,10,10);
                    using(var brush=new SolidBrush(Color.FromArgb(210,copper))) g.FillEllipse(brush,p.X-1.7f,p.Y-1.7f,3.4f,3.4f);
                }
            }
            Face(g,612,167-breathe,1.05f,copper,paper,time,moving);
            // 配准框只保留四角，给画面留白。
            using(var pen=new Pen(Color.FromArgb(125,copper),1.1f)) {
                foreach(int side in new[] {-1,1}) foreach(int vertical in new[] {-1,1}) {
                    float x=612+side*44, y=169+vertical*59;
                    g.DrawLines(pen,new[] {new PointF(x-side*9,y),new PointF(x,y),new PointF(x,y-vertical*9)});
                }
            }
            if(view=="ready") using(var pen=new Pen(copper,1.6f) { StartCap=LineCap.Round,EndCap=LineCap.Round })
                g.DrawLines(pen,new[] {new PointF(650,214),new PointF(654,218),new PointF(662,209)});
            g.Restore(state);
        }
    }

    public sealed class Launcher : Form {
        readonly SoftButton run = new SoftButton { Primary = true }, pause = new SoftButton(), close = new SoftButton(), minimize = new SoftButton();
        readonly SoftButton browse = new SoftButton(), detect = new SoftButton(), theme = new SoftButton();
        readonly Func<string> rootDetector;
        readonly Func<InstallDrive[]> driveSurvey;
        readonly DiskStrip diskPanel;
        readonly ToolTip driveTips = new ToolTip();
        InstallDrive[] drives = new InstallDrive[0];
        Bitmap diskIcon;
        readonly TextBox installPath = new TextBox();
        readonly GlowSwitch desktopShortcut = new GlowSwitch(), startMenuShortcut = new GlowSwitch();
        Bitmap brandMark;
        readonly Manifest manifest;
        readonly bool preview;
        bool dark;
        public bool IsDark { get { return dark; } }
        readonly System.Windows.Forms.Timer animation = new System.Windows.Forms.Timer { Interval = 16 };
        readonly Stopwatch animationClock = new Stopwatch();
        readonly Stopwatch artworkClock = new Stopwatch();
        public double? ArtworkPreviewSeconds { get; set; }
        double demoStart;
        CancellationTokenSource cancellation;
        string view = "idle", statusTitle = "一切准备，交给我们。", statusDetail = "选好位置后开始，自动补齐应用、依赖和模型。";
        double fraction, pulse;
        long downloaded, total;
        int installPhase;
        string completedRoot;
        bool maintenanceMode, maintenanceNeedsRepair;
        bool destinationBlocked;
        public static GraphicsPath Round(RectangleF r, float radius) {
            var p = new GraphicsPath(); float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
        }
        Color Paper { get { return dark ? Color.FromArgb(29, 31, 29) : Color.FromArgb(251, 250, 247); } }
        Color Ink { get { return dark ? Color.FromArgb(235, 233, 225) : Color.FromArgb(40, 43, 39); } }
        Color Muted { get { return dark ? Color.FromArgb(158, 161, 150) : Color.FromArgb(124, 128, 116); } }
        Color Accent { get { return dark ? Color.FromArgb(218, 166, 121) : Color.FromArgb(181, 123, 83); } }
        public Launcher(Manifest value, bool demonstration = false, bool? darkMode = null, Func<string> detectRoot = null, Func<InstallDrive[]> survey = null) {
            manifest = value; preview = demonstration; dark = darkMode ?? false;
            diskPanel=new DiskStrip(dark) { Name="local-disks", TabIndex=0 };
            rootDetector = detectRoot ?? (() => Maintenance.FindInstallation() ?? Installer.DefaultRoot(!preview));
            driveSurvey = survey ?? Installer.SurveyDrives;
            Text = "易容 Studio" + (preview ? " · 安装演示" : " 安装程序"); ClientSize = new Size(720, 830);
            AutoScaleMode = AutoScaleMode.None; Font = new Font("Microsoft YaHei UI", 10); BackColor = Paper;
            StartPosition = FormStartPosition.CenterScreen; FormBorderStyle = FormBorderStyle.None; DoubleBuffered = true;
            AccessibleName = "易容 Studio 启动器"; MaximizeBox = false;
            run.Text = "安装并运行  →"; run.AccessibleName = "安装并准备工作台"; run.TabIndex = 3;
            pause.Text = "暂停"; pause.AccessibleName = "暂停准备"; pause.Visible = false; pause.TabIndex = 1;
            close.Text = "×"; close.Name="close"; close.Glyph=ButtonGlyph.Close; close.AccessibleName = "关闭启动器"; close.TabIndex = 3;
            minimize.Text = "−"; minimize.Name="minimize"; minimize.Glyph=ButtonGlyph.Minimize; minimize.AccessibleName = "最小化"; minimize.TabIndex = 2;
            theme.Name="theme"; theme.Glyph=dark?ButtonGlyph.Sun:ButtonGlyph.Moon; theme.AccessibleName=dark?"切换浅色主题":"切换深色主题"; theme.TabIndex=5;
            driveTips.SetToolTip(theme,theme.AccessibleName);
            theme.Click+=(sender,args)=>ApplyTheme(!dark);
            foreach (var button in new[] { run, pause, close, minimize, browse, detect, theme }) { button.Dark = dark; button.BackColor = Paper; Controls.Add(button); }
            run.Name = "install"; detect.Name = "detect"; installPath.Name = "destination";
            installPath.BorderStyle = BorderStyle.None; installPath.BackColor = Paper; installPath.ForeColor = Ink;
            installPath.AccessibleName = "安装目录"; installPath.TabIndex = 0;
            browse.Text = "更改"; browse.AccessibleName = "选择安装目录"; browse.TabIndex = 1;
            detect.Text = "重新检测"; detect.AccessibleName = "重新检测分区空间和权限"; detect.TabIndex = 4;
            detect.Click += (sender, args) => DetectDestination();
            installPath.TextChanged += (sender, args) => {
                if (cancellation != null || completedRoot != null) return;
                maintenanceMode = maintenanceNeedsRepair = false;
                if (!String.IsNullOrWhiteSpace(installPath.Text)) { destinationBlocked = false; SetPreview("idle", 0); }
                run.Enabled = !String.IsNullOrWhiteSpace(installPath.Text);
                SyncDriveSelection();
            };
            desktopShortcut.Name="desktop-shortcut"; desktopShortcut.Text = "创建桌面快捷方式"; desktopShortcut.Dark=dark; desktopShortcut.Checked = true; desktopShortcut.BackColor = Paper; desktopShortcut.TabIndex = 2;
            startMenuShortcut.Name="start-menu-shortcut"; startMenuShortcut.Text = "添加到开始菜单"; startMenuShortcut.Dark=dark; startMenuShortcut.Checked = true; startMenuShortcut.BackColor = Paper; startMenuShortcut.TabIndex = 2;
            Controls.AddRange(new Control[] { installPath, desktopShortcut, startMenuShortcut });
            diskPanel.BackColor = Paper; Controls.Add(diskPanel);
            browse.Click += (sender, args) => {
                using (var picker = new FolderBrowserDialog { Description = "选择安装位置，将在其中创建专用 易容 Studio 文件夹", ShowNewFolderButton = true }) {
                    if (Directory.Exists(installPath.Text)) picker.SelectedPath = installPath.Text;
                    if (picker.ShowDialog(this) == DialogResult.OK) installPath.Text = Path.GetFileName(picker.SelectedPath).Equals("易容 Studio", StringComparison.OrdinalIgnoreCase) ? picker.SelectedPath : Path.Combine(picker.SelectedPath, "易容 Studio");
                }
            };
            try {
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("app-mark.png")) if (stream != null) using (var image = Image.FromStream(stream)) brandMark = new Bitmap(image);
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("installer.ico")) if (stream != null) Icon = new Icon(stream);
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("disk-local.png")) if (stream != null) using (var image = Image.FromStream(stream)) diskIcon = new Bitmap(image);
            } catch { }
            run.Click += async (sender, args) => {
                if (preview) StartDemo();
                else if (completedRoot != null) { OpenWorkspace(completedRoot); Close(); }
                else if (Maintenance.IsInstalled(installPath.Text.Trim())) await CheckInstallation(maintenanceNeedsRepair);
                else try { await Start(); } catch (Exception error) { MessageBox.Show(this,error.Message,"组件选择未完成",MessageBoxButtons.OK,MessageBoxIcon.Warning); }
            };
            pause.Click += (sender, args) => { if (preview) SetPreview("paused", fraction); else if (cancellation != null) cancellation.Cancel(); };
            close.Click += (sender, args) => Close(); minimize.Click += (sender, args) => WindowState = FormWindowState.Minimized;
            AcceptButton = run; CancelButton = pause;
            animation.Tick += (sender, args) => {
                double time = animationClock.Elapsed.TotalSeconds;
                double phase = (time % 2.8) / 1.4; pulse = BezierMotion.Ease(phase < 1 ? phase : 2-phase);
                if (preview && view == "downloading") {
                    fraction = demoStart + (1-demoStart)*BezierMotion.Ease(time / 8); downloaded = (long)(fraction * 111063687); total = 111063687;
                    installPhase = fraction > .55 ? 1 : 0;
                    if (time >= 8) SetPreview("ready", 1);
                }
                if(view=="downloading" || view=="working") Invalidate();
                else Invalidate(new Rectangle((int)(438*ClientSize.Width/720f),(int)(103*ClientSize.Height/830f),(int)(244*ClientSize.Width/720f)+1,(int)(140*ClientSize.Height/830f)+1));
            };
            Shown += async (sender,args) => {
                artworkClock.Start(); if(view=="idle") animation.Start();
                if(!preview && Maintenance.IsInstalled(installPath.Text.Trim())) await CheckInstallation(false);
            };
            Resize += (sender,args) => {
                if(WindowState==FormWindowState.Minimized) { animation.Stop(); artworkClock.Stop(); }
                else if(view=="idle" || view=="downloading" || view=="working") { artworkClock.Start(); animation.Start(); }
            };
            FormClosing += (sender, args) => { animation.Stop(); if (cancellation != null) cancellation.Cancel(); };
            Resize += (sender, args) => LayoutButtons(); LayoutButtons(); DetectDestination();
        }
        void ApplyTheme(bool value) {
            dark=value; BackColor=Paper;
            foreach(var button in new[] { run,pause,close,minimize,browse,detect,theme }) { button.Dark=dark; button.BackColor=Paper; button.Invalidate(); }
            theme.Glyph=dark?ButtonGlyph.Sun:ButtonGlyph.Moon; theme.AccessibleName=dark?"切换浅色主题":"切换深色主题";
            driveTips.SetToolTip(theme,theme.AccessibleName);
            installPath.BackColor=Paper; installPath.ForeColor=Ink;
            desktopShortcut.Dark=dark; desktopShortcut.BackColor=Paper; desktopShortcut.Invalidate();
            startMenuShortcut.Dark=dark; startMenuShortcut.BackColor=Paper; startMenuShortcut.Invalidate();
            diskPanel.SetTheme(dark);
            Invalidate();
        }
        void DetectDestination() {
            drives = driveSurvey();
            try { installPath.Text = rootDetector(); destinationBlocked = false; SetPreview("idle", 0); }
            catch (Exception error) {
                installPath.Clear(); destinationBlocked = true; view = "error"; fraction = 0; total = 0;
                string[] lines = error.Message.Split(new[] { '\n' }, 2);
                statusTitle = lines[0]; statusDetail = lines.Length > 1 ? lines[1] : "请调整安装位置或分区条件后重新检测。";
                run.Enabled = false; pause.Visible = false; animation.Stop();
                AccessibleDescription = error.Message; Invalidate();
            }
            BuildDriveCards();
        }
        void BuildDriveCards() {
            diskPanel.SuspendLayout();
            while (diskPanel.Controls.Count > 0) { var old = diskPanel.Controls[0]; diskPanel.Controls.RemoveAt(0); old.Dispose(); }
            int width = drives.Length > 4 ? 150 : (636 - Math.Max(0, drives.Length-1)*12) / Math.Max(1, drives.Length);
            foreach (var drive in drives) {
                string problem = Installer.DriveProblem(drive, drives);
                bool current = false;
                try { current = !String.IsNullOrWhiteSpace(installPath.Text) && String.Equals(Path.GetPathRoot(installPath.Text), drive.root, StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(installPath.Text, Installer.Marker)) && Installer.ReadState(installPath.Text).state != "uninstalled"; } catch { }
                string space = drive.ready ? (drive.free / 1073741824.0).ToString("0.#") + " GiB 可用" : "暂不可用";
                string detail = current ? "继续安装 · " + space : problem == null ? space : !drive.ready ? "暂不可用" : drive.root.StartsWith("C:", StringComparison.OrdinalIgnoreCase) && drives.Length > 1 ? "系统盘 · 优先其他分区" : "空间不足 · " + space;
                string resumableRoot = current ? installPath.Text : null;
                var card = new DiskCard(drive, diskIcon, dark, detail) { Size = new Size(width,132), Margin = new Padding(0,0,drive == drives.Last() ? 0 : 12,0), Enabled = current || problem == null };
                string folderHint = drive.root.StartsWith("C:",StringComparison.OrdinalIgnoreCase) ? "点击选择，应用将安装到无需提权的用户目录" : "点击选择，应用将安装到 Program Files\\易容 Studio";
                driveTips.SetToolTip(card, drive.root + "\n" + space + "\n" + (current ? "继续当前安装" : problem ?? folderHint));
                card.Click += (sender, args) => {
                    try {
                        installPath.Text = resumableRoot ?? Installer.RootOnDrive(card.Drive, drives, !preview);
                        destinationBlocked = false; SetPreview("idle",0); SyncDriveSelection();
                    } catch (Exception error) {
                        view = "error"; statusTitle = "这个磁盘暂时无法安装。"; statusDetail = error.Message;
                        AccessibleDescription = statusTitle + statusDetail; Invalidate();
                    }
                };
                diskPanel.Controls.Add(card);
            }
            diskPanel.ResumeLayout(); SyncDriveSelection();
        }
        void SyncDriveSelection() {
            string root = null;
            try { if (!String.IsNullOrWhiteSpace(installPath.Text)) root = Path.GetPathRoot(Path.GetFullPath(installPath.Text)); } catch { }
            foreach (DiskCard card in diskPanel.Controls) {
                bool selected = String.Equals(root,card.Drive.root,StringComparison.OrdinalIgnoreCase);
                if (card.Selected != selected) card.SetSelected(selected);
            }
        }
        protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ClassStyle |= 0x20000; return p; } }
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ReleaseCapture();
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left && e.Y < Height * .16 && e.X < Width * .82) { ReleaseCapture(); SendMessage(Handle, 0xA1, new IntPtr(2), IntPtr.Zero); }
        }
        void LayoutButtons() {
            float sx = ClientSize.Width / 720f, sy = ClientSize.Height / 830f;
            run.SetBounds((int)(498 * sx), (int)(764 * sy), (int)(180 * sx), (int)(46 * sy));
            pause.SetBounds((int)(392 * sx), (int)(764 * sy), (int)(92 * sx), (int)(46 * sy));
            detect.SetBounds((int)(44 * sx), (int)(764 * sy), (int)(120 * sx), (int)(46 * sy));
            diskPanel.SetBounds((int)(42*sx),(int)(262*sy),(int)(636*sx),(int)(150*sy));
            installPath.SetBounds((int)(59 * sx), (int)(444 * sy), (int)(507 * sx), (int)(23 * sy));
            browse.SetBounds((int)(588 * sx), (int)(436 * sy), (int)(80 * sx), (int)(35 * sy));
            desktopShortcut.SetBounds((int)(42 * sx), (int)(482 * sy), (int)(256 * sx), (int)(46 * sy));
            startMenuShortcut.SetBounds((int)(310 * sx), (int)(482 * sy), (int)(256 * sx), (int)(46 * sy));
            close.SetBounds((int)(666 * sx), (int)(27 * sy), (int)(28 * sx), (int)(28 * sy));
            minimize.SetBounds((int)(630 * sx), (int)(27 * sy), (int)(28 * sx), (int)(28 * sy));
            theme.SetBounds((int)(594 * sx), (int)(27 * sy), (int)(28 * sx), (int)(28 * sy));
            using (var shape = Round(new RectangleF(0, 0, ClientSize.Width, ClientSize.Height), 22)) { var old = Region; Region = new Region(shape); if (old != null) old.Dispose(); }
            Invalidate();
        }
        void TextAt(Graphics g, string text, float size, Color color, float x, float y, float width, bool bold = false) {
            using (var font = new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel))
            using (var brush = new SolidBrush(color)) g.DrawString(text, font, brush, new RectangleF(x, y, width, size * 2.7f));
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e); var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.ScaleTransform(ClientSize.Width / 720f, ClientSize.Height / 830f);
            using (var shape = Round(new RectangleF(0.5f, .5f, 719, 829), 22)) using (var border = new Pen(dark ? Color.FromArgb(58, 61, 55) : Color.FromArgb(224, 225, 216))) g.DrawPath(border, shape);
            if (brandMark != null) g.DrawImage(brandMark, new Rectangle(36, 28, 50, 50));
            else TextAt(g, "F", 28, Accent, 48, 36, 32, true);
            TextAt(g, "易容 Studio", 16, Ink, 92, 35, 200, true); TextAt(g, "AI 人脸融合工作台", 9, Muted, 93, 60, 200);
            TextAt(g, "本地 AI 换脸工作台", 11, Muted, 438, 43, 140);
            TextAt(g, maintenanceMode ? "让创作，保持顺畅。" : "新形象，从这里开始。", 31, Ink, 40, 133, 420);
            TextAt(g, maintenanceMode ? "先检查，按需修复；保留模型、配置与作品。" : "选择安装位置，剩下的交给我们。", 14, Muted, 43, 183, 400);
            FaceFusionArtwork.Draw(g,dark,ArtworkPreviewSeconds ?? artworkClock.Elapsed.TotalSeconds,view);
            TextAt(g, "安装位置", 12, Muted, 43, 240, 130);
            TextAt(g, "非 C 盘优先 · 至少 12 GiB", 11, Muted, 480, 242, 210);
            TextAt(g, "安装到专用应用文件夹", 11, Muted, 44, 411, 400);
            using (var shape = Round(new RectangleF(42, 430, 636, 48), 12)) using (var pen = new Pen(dark ? Color.FromArgb(65, 70, 60) : Color.FromArgb(218, 222, 209))) g.DrawPath(pen, shape);
            g.TranslateTransform(0, 280);
            using (var shape = Round(new RectangleF(42, 268, 636, 144), 18)) using (var brush = new SolidBrush(dark ? Color.FromArgb(38, 41, 36) : Color.FromArgb(242, 242, 235))) g.FillPath(brush, shape);
            var textLayout=PreparationTextLayout.Measure(g,statusTitle,destinationBlocked || view=="error");
            DrawStatusText(g,statusTitle,textLayout.TitleSize,Ink,textLayout.Title,true);
            string amount = destinationBlocked ? "需处理" : total > 0 ? Math.Round(fraction * 100) + "%" : (view == "idle" ? "等待开始" : view == "ready" ? "已就绪" : view == "paused" ? "已暂停" : "准备中");
            DrawStatusText(g,amount,12,Muted,textLayout.Percent,false);
            if (destinationBlocked || view == "error") {
                DrawStatusText(g,statusDetail,12,Muted,textLayout.Detail,false);
            } else {
            DrawStatusText(g,statusDetail,12,Muted,textLayout.Detail,false);
            using (var shape = Round(textLayout.Bar, 2.5f)) using (var brush = new SolidBrush(dark ? Color.FromArgb(61, 66, 55) : Color.FromArgb(223, 226, 213))) g.FillPath(brush, shape);
            float filled = (float)(594 * fraction);
            if (filled > 2) using (var shape = Round(new RectangleF(textLayout.Bar.X,textLayout.Bar.Y,filled,5), 2.5f)) using (var brush = new SolidBrush(Accent)) g.FillPath(brush, shape);
            if (total == 0 && view == "working") using (var brush = new SolidBrush(Accent)) g.FillRectangle(brush,textLayout.Bar.X+(float)(pulse*464),textLayout.Bar.Y,130,5);
            DrawStatusText(g,maintenanceMode ? "程序、环境与模型按可信清单核验" : total > 0 ? String.Format("{0:F1} MB / {1:F1} MB", downloaded / 1048576.0, total / 1048576.0) : "首次联网准备 · 已有资源自动复用",10,Muted,textLayout.Footnote,false);
            }
            string[] steps = maintenanceMode ? new[] { "检查安装", "按需修复", "完成复检" } : new[] { "安装应用", "准备环境", "完成安装" };
            for (int i = 0; i < 3; i++) {
                int x = 44 + i * 211; bool active = i == installPhase;
                using (var brush = new SolidBrush(active ? Accent : (dark ? Color.FromArgb(58, 62, 53) : Color.FromArgb(232, 234, 225)))) g.FillEllipse(brush, x, 422, 20, 20);
                TextAt(g, i < installPhase ? "✓" : (i + 1).ToString(), 10, active ? Paper : Muted, x + 5, 425, 20);
                TextAt(g, steps[i], 11, active ? Ink : Muted, x + 29, 424, 125);
                if (i < 2) using (var pen = new Pen(dark ? Color.FromArgb(55, 60, 49) : Color.FromArgb(226, 229, 217))) g.DrawLine(pen, x + 126, 432, x + 190, 432);
            }
            using (var brush = new SolidBrush(Accent)) g.FillEllipse(brush, 44, 455, 5, 5);
            TextAt(g, preview ? "安装演示 · 不会下载或修改系统" : maintenanceMode ? "健康检查不关闭工作台 · 修复保留个人数据" : "当前用户安装 · 无需管理员权限", 11, Muted, 56, 449, 430);
        }
        static void DrawStatusText(Graphics graphics,string text,float size,Color color,RectangleF bounds,bool bold) {
            var state=graphics.Save(); graphics.SetClip(bounds);
            using(var font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular,GraphicsUnit.Pixel))
            using(var brush=new SolidBrush(color))
            using(var format=new StringFormat { Trimming=StringTrimming.EllipsisWord,FormatFlags=StringFormatFlags.LineLimit })
                graphics.DrawString(text,font,brush,bounds,format);
            graphics.Restore(state);
        }
        public void SetPreparationProgress(Status status,int phase) {
            installPhase=phase; statusTitle=status.text;
            statusDetail=phase==0?"正在安装应用，下载内容会自动保存。":"正在补齐依赖和模型，完成后自动登记安装。";
            downloaded=status.done; total=status.total;
            if(total>0) fraction=Math.Max(0,Math.Min(1,(double)downloaded/total));
            AccessibleDescription=statusTitle+statusDetail; Invalidate();
        }
        public void SetPreview(string state, double value) {
            view = state; fraction = Math.Max(0, Math.Min(1, value)); downloaded = (long)(fraction * 111063687); total = state == "idle" ? 0 : 111063687;
            if (state == "idle") { installPhase = 0; statusTitle = "一切准备，交给我们。"; statusDetail = "选好位置后开始，自动补齐应用、依赖和模型。"; run.Text = "安装并运行  →"; }
            else if (state == "paused") { statusTitle = "稍作停留，进度还在。"; statusDetail = "已保留下载内容，随时可以继续。"; run.Text = "继续准备  →"; }
            else if (state == "ready") { installPhase = 2; statusTitle = "安装完成，开始创作。"; statusDetail = "已准备运行环境，并按你的选择创建快捷方式。"; run.Text = preview ? "重新演示  ↻" : "开始创作  →"; }
            else { statusTitle = "正在准备你的创作空间。"; statusDetail = "从魔搭补齐桌面环境，完成后自动打开工作台。"; run.Text = "正在准备…"; }
            run.Enabled = state != "downloading" && state != "working"; pause.Visible = state == "downloading" || state == "working";
            if (state == "downloading" || state == "working") { animationClock.Restart(); artworkClock.Start(); animation.Start(); }
            else if(state=="idle") { animationClock.Stop(); artworkClock.Start(); animation.Start(); }
            else { animation.Stop(); animationClock.Stop(); artworkClock.Stop(); }
            AccessibleDescription = statusTitle + statusDetail; Invalidate();
        }
        public void SetMaintenancePreview(string state) {
            if(!preview) throw new InvalidOperationException("仅用于演示渲染");
            SetPreview(state=="healthy" ? "ready" : state=="error" ? "error" : state=="damaged" ? "paused" : "working",state=="healthy"?1:.42);
            maintenanceMode=true; installPhase=state=="healthy"?2:state=="repairing"?1:0;
            statusTitle=state=="healthy"?"检查完成，一切正常。":state=="damaged"?"发现需要修复的内容。":state=="repairing"?"正在修复安装。":state=="error"?"检查或修复未能完成。":"正在检查安装。";
            statusDetail=state=="healthy"?Maintenance.HealthyMessage:state=="damaged"?"发现 2 项问题；修复将正常关闭本目录工作台并保留个人数据。":state=="repairing"?"正在恢复缺失的运行环境，模型、配置与作品保持原样。":state=="error"?"修复后复检未通过，已回滚本次修改。请保留检查日志后重试。":"正在校验程序、Python 环境及模型；不会关闭已运行的工作台。";
            run.Text=state=="healthy"?"开始创作  →":state=="damaged"?"开始修复  →":state=="error"?"重新检查  →":"正在检查…";
            Invalidate();
        }
        void StartDemo() { if (view == "ready") fraction = 0; demoStart = fraction; installPhase = fraction > .55 ? 1 : 0; SetPreview("downloading", fraction); }
        static void OpenWorkspace(string root) {
            var start = new ProcessStartInfo(Path.Combine(root, "易容 Studio.exe"), "--faceswap-run --faceswap-show") { WorkingDirectory = root, UseShellExecute = false };
            start.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE"); start.EnvironmentVariables["FACESWAP_STUDIO_DATA_ROOT"] = Path.Combine(root, "data"); Process.Start(start);
        }
        async Task CheckInstallation(bool repair) {
            if(cancellation != null) return;
            string root = Installer.Canonical(installPath.Text.Trim());
            maintenanceMode = true; maintenanceNeedsRepair = false;
            installPhase = repair ? 1 : 0;
            cancellation = new CancellationTokenSource(); view="working"; fraction=0;
            statusTitle=repair ? "正在修复安装。" : "正在检查安装。";
            statusDetail=repair ? "仅处理缺失或损坏的文件，个人数据保持原样。" : "检查不会关闭已运行的工作台。";
            run.Enabled=false; pause.Visible=true;
            installPath.Enabled=browse.Enabled=detect.Enabled=diskPanel.Enabled=desktopShortcut.Enabled=startMenuShortcut.Enabled=false;
            animation.Start(); Invalidate();
            var reporter=new Progress<Status>(value=> {
                if(IsDisposed) return;
                statusDetail=value.text; downloaded=value.done; total=value.total;
                fraction=total>0 ? Math.Max(0,Math.Min(1,(double)downloaded/total)) : 0;
                Invalidate();
            });
            try {
                var result=await Task.Run(()=>Maintenance.Run(root,manifest,repair,cancellation.Token,reporter));
                if(IsDisposed) return;
                if(result.status=="damaged") {
                    view="paused"; statusTitle="发现需要修复的内容。";
                    statusDetail=result.message+"\n"+String.Join("；",result.issues.Take(2));
                    maintenanceNeedsRepair=true; run.Text="开始修复  →";
                } else {
                    completedRoot=root; view="ready"; fraction=1; installPhase=2;
                    statusTitle=result.repaired ? "修复完成，开始创作吧。" : "检查完成，一切正常。";
                    statusDetail=result.message; run.Text="开始创作  →";
                }
            } catch(OperationCanceledException) {
                if(!IsDisposed) { view="paused";statusTitle="检查或修复已取消。";statusDetail="已完成的替换会回滚，原数据保留。";run.Text="重新检查  →"; }
            } catch(Exception error) {
                if(!IsDisposed) { view="error";statusTitle="检查或修复未能完成。";statusDetail=error.Message;run.Text="重新检查  →"; }
            } finally {
                cancellation.Dispose(); cancellation=null;
                if(!IsDisposed) { animation.Stop();pause.Visible=false;run.Enabled=true;Invalidate(); }
            }
        }
        async Task Start() {
            ComponentSelection selection = null;
            if (manifest.componentProtocol >= 2) {
                int memory = await Task.Run(() => ComponentPicker.GpuMemory());
                using (var picker = new ComponentPicker(manifest, installPath.Text.Trim(), memory, dark)) {
                    if (picker.ShowDialog(this) != DialogResult.OK) return;
                    selection = picker.Selection;
                }
            }
            SetPreview("working", fraction); total = 0; cancellation = new CancellationTokenSource();
            string root = installPath.Text.Trim(); Process child = null; FileStream lease = null; bool complete = false, owned = false;
            installPath.Enabled = browse.Enabled = detect.Enabled = diskPanel.Enabled = desktopShortcut.Enabled = startMenuShortcut.Enabled = false;
            var reporter = new Progress<Status>(status => {
                if (IsDisposed) return;
                SetPreparationProgress(status,installPhase);
            });
            try {
                root = Installer.Canonical(root); installPath.Text = root;
                Installer.ValidateDestinationCapacity(root);
                if (selection != null) ComponentPicker.ValidateCapacity(root, selection, manifest);
                lease = Installer.AcquireRoot(root);
                Installer.Begin(root, manifest, lockHeld: true);
                if (selection != null) ComponentPicker.Save(root, selection);
                owned = true;
                await Task.Run(() => Installer.InstallUninstaller(root));
                await Task.Run(() => Core.Prepare(root, manifest, cancellation.Token, reporter));
                Installer.ExtractResource("app.ico", Path.Combine(root, "faceswap.ico"));
                Installer.ExtractResource("installer.ico", Path.Combine(root, "faceswap-installer.ico"));
                installPhase = 1; fraction = 0; total = 0; Invalidate();
                string session = Guid.NewGuid().ToString("N"), report = Path.Combine(root, "data", "cache", "install", session + ".json");
                Directory.CreateDirectory(Path.GetDirectoryName(report));
                child = Installer.StartPreparation(root, report, session);
                await Installer.WaitForReady(root, report, session, child, cancellation.Token, reporter, manifest.componentProtocol >= 2);
                Installer.Complete(root, manifest, desktopShortcut.Checked, startMenuShortcut.Checked, readyReport: report, session: session);
                complete = true; completedRoot = root; SetPreview("ready", 1); run.Enabled = false; await Task.Delay(350, cancellation.Token);
                cancellation.Token.ThrowIfCancellationRequested();
                Close();
            } catch (OperationCanceledException) { if (!IsDisposed) SetPreview("paused", fraction); }
            catch (Exception error) {
                if (!IsDisposed) { view = "error"; statusTitle = "暂时未能完成准备。"; statusDetail = error.Message; animation.Stop(); run.Text = "重试  →"; Invalidate(); }
                if (owned) try { File.AppendAllText(Path.Combine(root, "bootstrap.log"), DateTimeOffset.Now + " " + error + Environment.NewLine); } catch { }
            } finally {
                if (!complete) Installer.StopChild(child);
                if (child != null) child.Dispose();
                if (lease != null) lease.Dispose();
                cancellation.Dispose(); cancellation = null;
                if (!IsDisposed) { run.Enabled = !String.IsNullOrWhiteSpace(installPath.Text); pause.Visible = false; installPath.Enabled = browse.Enabled = detect.Enabled = diskPanel.Enabled = desktopShortcut.Enabled = startMenuShortcut.Enabled = !complete; }
            }
        }
        protected override void Dispose(bool disposing) { if (disposing) { animation.Dispose(); driveTips.Dispose(); if (brandMark != null) brandMark.Dispose(); if (diskIcon != null) diskIcon.Dispose(); } base.Dispose(disposing); }
    }
    public static class Program {
        [STAThread] public static void Main(string[] args) {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try {
                if (Installer.RouteUninstall(args)) return;
                Manifest manifest;
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("bootstrap-manifest.json"))
                using (var unpack = new GZipStream(stream, CompressionMode.Decompress))
                using (var reader = new StreamReader(unpack)) manifest = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 }.Deserialize<Manifest>(reader.ReadToEnd());
                Core.Validate(manifest);
                if(Maintenance.Route(args,manifest)) return;
                string identity;
                using (var hash = SHA256.Create()) identity = BitConverter.ToString(hash.ComputeHash(System.Text.Encoding.UTF8.GetBytes(AppDomain.CurrentDomain.BaseDirectory.ToUpperInvariant()))).Replace("-", "");
                using (var mutex = new Mutex(false, "Local\\FaceSwap-Bootstrap-" + identity)) {
                    if (!mutex.WaitOne(0)) { MessageBox.Show("启动器已在运行，请查看已有窗口。", "易容 Studio"); return; }
                    bool demo = args.Contains("--demo");
#if DEMO
                    demo = true;
#endif
                    try { Application.Run(new Launcher(manifest, demo)); } finally { mutex.ReleaseMutex(); }
                }
            } catch (Exception error) { MessageBox.Show(error.Message, "易容 Studio 启动未完成", MessageBoxButtons.OK, MessageBoxIcon.Error); Environment.ExitCode = 1; }
        }
    }
}
