using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace FaceSwapBootstrap {
    // 按安装器同一份 SoftButton、PreparationTextLayout 和 FaceFusionArtwork 源码构建。
    public class StudioUpdateSurface : Form {
        public readonly SoftButton PrimaryAction=new SoftButton{Primary=true}, SecondaryAction=new SoftButton(), ReturnAction=new SoftButton();
        readonly SoftButton theme=new SoftButton(), minimize=new SoftButton(), close=new SoftButton();
        readonly System.Windows.Forms.Timer animation=new System.Windows.Forms.Timer{Interval=33};
        readonly Stopwatch clock=Stopwatch.StartNew();
        Bitmap brand;
        bool dark;
        float noteOffset;
        public string VersionText="", ReleaseNotes="", StatusTitle="发现新的功能与改进", StatusDetail="现在更新即可体验，也可以留到下次启动。", View="idle";
        public double Fraction;
        public double? ArtworkPreviewSeconds;
        public bool IsDark {get{return dark;}}
        public bool IsBusy {set{close.Enabled=!value;}}
        Color Paper {get{return dark?Color.FromArgb(29,31,29):Color.FromArgb(251,250,247);}}
        Color Ink {get{return dark?Color.FromArgb(235,233,225):Color.FromArgb(40,43,39);}}
        Color Muted {get{return dark?Color.FromArgb(158,161,150):Color.FromArgb(124,128,116);}}
        Color Accent {get{return dark?Color.FromArgb(218,166,121):Color.FromArgb(181,123,83);}}
        public StudioUpdateSurface() {
            AutoScaleMode=AutoScaleMode.None;FormBorderStyle=FormBorderStyle.None;DoubleBuffered=true;
            var area=Screen.FromPoint(Cursor.Position).WorkingArea;
            ClientSize=new Size(Math.Min(720,area.Width-40),Math.Min(760,area.Height-40));
            StartPosition=FormStartPosition.CenterScreen;Font=new Font("Microsoft YaHei UI",10);MaximizeBox=false;
            AccessibleName="易容 Studio 软件更新";
            try {using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("app-mark.png"))
                if(stream!=null)using(var image=Image.FromStream(stream))brand=new Bitmap(image);}catch{}
            theme.Name="theme";theme.AccessibleName="切换深浅主题";theme.Click+=(s,e)=>SetDark(!dark);
            minimize.Glyph=ButtonGlyph.Minimize;minimize.AccessibleName="最小化";minimize.Click+=(s,e)=>WindowState=FormWindowState.Minimized;
            close.Glyph=ButtonGlyph.Close;close.AccessibleName="关闭更新器";close.Click+=(s,e)=>Close();
            Controls.AddRange(new Control[]{PrimaryAction,SecondaryAction,ReturnAction,theme,minimize,close});
            Resize+=(s,e)=>{LayoutSurface();UpdateAnimation();};VisibleChanged+=(s,e)=>UpdateAnimation();
            animation.Tick+=(s,e)=>Invalidate(new Rectangle((int)(438*ClientSize.Width/720f),(int)(103*ClientSize.Height/760f),(int)(244*ClientSize.Width/720f)+2,(int)(140*ClientSize.Height/760f)+2));
            SetDark(false);LayoutSurface();
        }
        public static GraphicsPath Round(RectangleF r,float radius) {
            var path=new GraphicsPath();float d=Math.Min(radius*2,Math.Min(r.Width,r.Height));
            path.AddArc(r.X,r.Y,d,d,180,90);path.AddArc(r.Right-d,r.Y,d,d,270,90);
            path.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);path.AddArc(r.X,r.Bottom-d,d,d,90,90);path.CloseFigure();return path;
        }
        public void SetDark(bool value) {
            dark=value;BackColor=Paper;theme.Glyph=dark?ButtonGlyph.Sun:ButtonGlyph.Moon;
            foreach(var button in new[]{PrimaryAction,SecondaryAction,ReturnAction,theme,minimize,close}) {button.Dark=dark;button.BackColor=Paper;button.Invalidate();}
            Invalidate();
        }
        void UpdateAnimation() {if(Visible && WindowState!=FormWindowState.Minimized && (View=="idle"||View=="downloading"||View=="working"))animation.Start();else animation.Stop();}
        public void RefreshSurface() {AccessibleDescription=VersionText+"。"+ReleaseNotes+"。"+StatusTitle+"。"+StatusDetail;UpdateAnimation();Invalidate();}
        void LayoutControl(Control c,int x,int y,int w,int h) {c.SetBounds((int)(x*ClientSize.Width/720f),(int)(y*ClientSize.Height/760f),(int)(w*ClientSize.Width/720f),(int)(h*ClientSize.Height/760f));}
        void LayoutSurface() {
            if(ClientSize.Width<1||ClientSize.Height<1)return;
            LayoutControl(PrimaryAction,498,694,180,46);LayoutControl(SecondaryAction,302,694,182,46);LayoutControl(ReturnAction,44,694,128,46);
            LayoutControl(theme,594,27,28,28);LayoutControl(minimize,630,27,28,28);LayoutControl(close,666,27,28,28);
            using(var shape=Round(new RectangleF(0,0,ClientSize.Width,ClientSize.Height),22)) {var previous=Region;Region=new Region(shape);if(previous!=null)previous.Dispose();}
            Invalidate();
        }
        protected override CreateParams CreateParams {get{var p=base.CreateParams;p.ClassStyle|=0x20000;return p;}}
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr handle,int message,IntPtr w,IntPtr l);
        protected override void OnMouseDown(MouseEventArgs e) {base.OnMouseDown(e);if(e.Button==MouseButtons.Left&&e.Y<ClientSize.Height*95/760f&&e.X<ClientSize.Width*.8f) {ReleaseCapture();SendMessage(Handle,0xA1,new IntPtr(2),IntPtr.Zero);}}
        protected override void OnMouseWheel(MouseEventArgs e) {base.OnMouseWheel(e);if(e.Y>ClientSize.Height*260/760f&&e.Y<ClientSize.Height*450/760f) {noteOffset=Math.Max(0,noteOffset-e.Delta*.35f);Invalidate();}}
        static void TextAt(Graphics g,string text,float size,Color color,RectangleF bounds,bool bold=false) {
            var state=g.Save();g.SetClip(bounds);
            using(var font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular,GraphicsUnit.Pixel))
            using(var brush=new SolidBrush(color))g.DrawString(text,font,brush,bounds);
            g.Restore(state);
        }
        void TextAt(Graphics g,string text,float size,Color color,float x,float y,float width,bool bold=false) {TextAt(g,text,size,color,new RectangleF(x,y,width,size*2.7f),bold);}
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.TextRenderingHint=System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.ScaleTransform(ClientSize.Width/720f,ClientSize.Height/760f);
            using(var shape=Round(new RectangleF(.5f,.5f,719,759),22))using(var border=new Pen(dark?Color.FromArgb(58,61,55):Color.FromArgb(224,225,216)))g.DrawPath(border,shape);
            if(brand!=null)g.DrawImage(brand,new Rectangle(36,28,50,50));
            TextAt(g,"易容 Studio",16,Ink,92,35,210,true);TextAt(g,"软件更新",10,Muted,93,60,200);
            string hero=View=="ready"?"新的体验，准备好了。":View=="error"?"稍作调整，再次出发。":View=="idle"?"让创作，持续焕新。":"好变化，即将就绪。";
            TextAt(g,hero,31,Ink,40,133,400);
            TextAt(g,"新功能与细节改进，为下一次创作准备。",14,Muted,43,183,390);
            FaceFusionArtwork.Draw(g,dark,ArtworkPreviewSeconds??clock.Elapsed.TotalSeconds,View);
            Color card=dark?Color.FromArgb(38,41,36):Color.FromArgb(242,242,235);
            using(var shape=Round(new RectangleF(42,260,636,190),18))using(var brush=new SolidBrush(card))g.FillPath(brush,shape);
            TextAt(g,"本次更新",13,Ink,63,279,200,true);TextAt(g,VersionText,11,Muted,320,282,335);
            using(var font=new Font("Microsoft YaHei UI",13,GraphicsUnit.Pixel)) {
                string text=String.IsNullOrWhiteSpace(ReleaseNotes)?"优化使用体验，带来新的功能与细节改进。":ReleaseNotes;
                float height=g.MeasureString(text,font,new SizeF(580,10000)).Height;
                noteOffset=Math.Min(noteOffset,Math.Max(0,height-108));
                var state=g.Save();g.SetClip(new RectangleF(63,317,584,110));
                using(var brush=new SolidBrush(Muted))g.DrawString(text,font,brush,new RectangleF(63,317-noteOffset,580,Math.Max(110,height+8)));
                g.Restore(state);
                if(height>110)using(var brush=new SolidBrush(dark?Color.FromArgb(74,78,68):Color.FromArgb(208,212,198))) {
                    float thumb=Math.Max(24,110*110/height);using(var shape=Round(new RectangleF(655,317+(110-thumb)*noteOffset/Math.Max(1,height-108),3,thumb),1.5f))g.FillPath(brush,shape);
                }
            }
            using(var shape=Round(new RectangleF(42,474,636,144),18))using(var brush=new SolidBrush(card))g.FillPath(brush,shape);
            var status=g.Save();g.TranslateTransform(0,206);
            var layout=PreparationTextLayout.Measure(g,StatusTitle,View=="error");
            TextAt(g,StatusTitle,layout.TitleSize,Ink,layout.Title,true);
            TextAt(g,View=="idle"?"可更新":View=="error"?"需处理":Math.Round(Fraction*100)+"%",12,Muted,layout.Percent);
            TextAt(g,StatusDetail,12,Muted,layout.Detail);
            if(View!="error") {
                using(var shape=Round(layout.Bar,2.5f))using(var brush=new SolidBrush(dark?Color.FromArgb(61,66,55):Color.FromArgb(223,226,213)))g.FillPath(brush,shape);
                if(Fraction>.003)using(var shape=Round(new RectangleF(layout.Bar.X,layout.Bar.Y,(float)(layout.Bar.Width*Fraction),5),2.5f))using(var brush=new SolidBrush(Accent))g.FillPath(brush,shape);
            }
            g.Restore(status);
            int phase=Fraction>=.9?2:Fraction>=.28?1:0;string[] steps={"下载更新","安装更新","启动确认"};
            for(int i=0;i<3;i++) {
                int x=44+i*211;bool active=View!="idle"&&i==phase;
                using(var brush=new SolidBrush(active?Accent:(dark?Color.FromArgb(58,62,53):Color.FromArgb(232,234,225))))g.FillEllipse(brush,x,640,20,20);
                TextAt(g,i<phase?"✓":(i+1).ToString(),10,active?Paper:Muted,x+5,643,20);
                TextAt(g,steps[i],11,active?Ink:Muted,x+29,642,125);
                if(i<2)using(var pen=new Pen(dark?Color.FromArgb(55,60,49):Color.FromArgb(226,229,217)))g.DrawLine(pen,x+126,650,x+190,650);
            }
            using(var brush=new SolidBrush(Accent))g.FillEllipse(brush,44,673,5,5);
            TextAt(g,"保留作品、人物形象与设置",11,Muted,56,667,440);
        }
        protected override void Dispose(bool disposing) {if(disposing) {animation.Dispose();if(brand!=null)brand.Dispose();}base.Dispose(disposing);}
    }
}
