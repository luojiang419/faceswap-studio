"""真实录屏剪辑：检测静止、贝塞尔镜头、中文字幕与双画幅输出。"""
from pathlib import Path
import argparse
import json
import math
import re
import subprocess
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import wave

ROOT = Path(r'G:\app\facefusion\output\宣传片\20261023')
RAW = ROOT / 'raw'
FONT = 'C:/Windows/Fonts/msyh.ttc'
BOLD = 'C:/Windows/Fonts/msyhbd.ttc'
PEACH = (255, 177, 123)
FPS = 30
BG = (18, 19, 22)

def font(size, bold=False):
    return ImageFont.truetype(BOLD if bold else FONT, size)

def bezier(u):
    # cubic-bezier(1/3, 0, 2/3, 1)：横轴参数线性，纵轴三次缓入缓出。
    u = max(0.0, min(1.0, u))
    return u*u*(3-2*u)

def detect_static(path):
    """5 Hz 低清差分，忽略单个鼠标/光标闪烁，长静止只保留首尾阅读缓冲。"""
    target = ROOT/'qa'/f'{path.stem}-motion.json'
    if target.exists(): return json.loads(target.read_text(encoding='utf8'))
    proc = subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(path),
        '-vf','fps=5,scale=346:166,format=gray','-f','rawvideo','-'], capture_output=True, check=True)
    frames = np.frombuffer(proc.stdout, np.uint8).reshape(-1,166,346)
    changed = np.zeros(len(frames),bool)
    changed[0] = True
    for i in range(1,len(frames)):
        diff = np.abs(frames[i].astype(np.int16)-frames[i-1].astype(np.int16))
        changed[i] = (diff > 8).sum() > 55
    intervals=[]; start=None
    for i, active in enumerate(changed):
        if not active and start is None: start=i/5
        if (active or i==len(changed)-1) and start is not None:
            end=i/5
            if end-start > 2.8: intervals.append([round(start,2),round(end,2)])
            start=None
    report={'source':str(path),'sampleRate':5,'duration':len(frames)/5,'staticIntervals':intervals,
            'staticSeconds':round(sum(b-a for a,b in intervals),2)}
    target.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    return report

def compact_span(name, start, end):
    report=detect_static(RAW/name)
    parts=[]; pos=start
    for a,b in report['staticIntervals']:
        cut_a=max(start,a+0.9); cut_b=min(end,b-0.45)
        if cut_b > cut_a and cut_b-cut_a > 0.8:
            if cut_a>pos: parts.append([pos,cut_a])
            pos=max(pos,cut_b)
    if pos<end: parts.append([pos,end])
    return parts or [[start,min(end,start+1.2)]]

W='workflow-recovered.mp4'
CHAPTERS = [
    {'id':'intro','title':'一张人脸，一段视频','sub':'易容 Studio · 本地换脸工作台',
     'shots':[(W,102,105,'preview'),('result-playback.mp4',9.8,12,'film')]},
    {'id':'source','title':'01  准备素材','sub':'人脸参考 + 待处理视频',
     'shots':[('library.mp4',20.5,30.2,'source')]},
    {'id':'preview','title':'02  先预览，再生成','sub':'定位正脸 · 检查五官、肤色与边缘',
     'shots':[('scrub.mp4',10,16,'scrub'),(W,82.5,87,'preview'),(W,95,98,'preview'),(W,166,173,'preview')]},
    {'id':'options','title':'需要微调，就展开参数','sub':'模型、输出与遮罩 · 改完重新预览',
     'shots':[(W,192,198,'options'),(W,218,224,'options'),(W,240,244,'options'),(W,250,256,'options')]},
    {'id':'generate','title':'03  点击立即生成','sub':'在生成队列查看进度与完成状态',
     'shots':[(W,277.5,283.5,'generate'),(W,286,329,'queue')]},
    {'id':'result','title':'完成后，播放检查细节','sub':'队列原位播放 · 双击放大查看',
     'shots':[(W,350,357,'queue'),('result-playback.mp4',2.3,4.5,'film'),('result-playback.mp4',9.8,12,'film')]},
    {'id':'works','title':'结果与人物，随时复用','sub':'作品管理 · 下载 / 打开路径 · 人物形象库',
     'shots':[('works.mp4',11,16,'works'),('works.mp4',23,29,'works'),('persona.mp4',11.2,15,'persona')]},
    {'id':'outro','title':'准备素材 → 预览确认 → 生成查看','sub':'易容 Studio · 快速入门',
     'shots':[('library.mp4',23,26,'source'),(W,166.5,170,'preview'),('result-playback.mp4',9.5,12,'film'),('persona.mp4',13,15,'persona')]},
]

def make_audio():
    report=json.loads((ROOT/'audio/voice-report.json').read_text(encoding='utf8'))
    items={s['id']:s for s in report['segments']}
    output=ROOT/'旁白_中国青年男声_声音设计.wav'
    assembled=[]; cursor=0; subtitles=[]
    for ch in CHAPTERS:
        target=ROOT/'audio'/f"{ch['id']}-normalized.wav"
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',items[ch['id']]['path'],
          '-af','atempo=0.94,loudnorm=I=-16:TP=-1.5:LRA=9','-ar','48000','-ac','1',
          '-c:a','pcm_s16le','-y',str(target)],check=True)
        with wave.open(str(target),'rb') as w: data=np.frombuffer(w.readframes(w.getnframes()),np.int16).copy()
        # 与帧率对齐，避免音画累计漂移。
        total_frames=math.ceil((len(data)/48000+0.28)*FPS)
        duration=total_frames/FPS
        data=np.pad(data,(0,round(duration*48000)-len(data)))
        ch.update(start=cursor,duration=duration,text=items[ch['id']]['text'])
        assembled.append(data)
        # 按句拆字幕，避免满屏长段落。短停顿按标点权重分配时间。
        phrases=[s for s in re.split(r'[，。！？；：]',ch['text']) if s]
        fragments=[]
        for p in phrases:
            while len(p)>22:
                fragments.append(p[:14]);p=p[14:]
            if p: fragments.append(p)
        weights=[len(p)+1.5 for p in fragments]; total=sum(weights); local=0.08
        speech_duration=len(data)/48000-0.28
        for p,weight in zip(fragments,weights):
            span=(speech_duration-0.08)*weight/total
            subtitles.append({'start':cursor+local,'end':cursor+local+span,'text':p})
            local+=span
        cursor+=duration
    with wave.open(str(output),'wb') as w:
        w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000);w.writeframes(np.concatenate(assembled).tobytes())
    def stamp(t):
        ms=round(t*1000);h,ms=divmod(ms,3600000);m,ms=divmod(ms,60000);s,ms=divmod(ms,1000)
        return f'{h:02}:{m:02}:{s:02},{ms:03}'
    (ROOT/'字幕.srt').write_text('\n\n'.join(f"{i+1}\n{stamp(s['start'])} --> {stamp(s['end'])}\n{s['text']}" for i,s in enumerate(subtitles)),encoding='utf8')
    (ROOT/'文案.txt').write_text('\n\n'.join(f"{c['title']}\n{c['text']}" for c in CHAPTERS),encoding='utf8')
    return output,subtitles,cursor

class Reader:
    def __init__(self,path):
        self.cap=cv2.VideoCapture(str(path));self.fps=self.cap.get(cv2.CAP_PROP_FPS);self.index=-1;self.frame=None
    def get(self,t):
        n=round(t*self.fps)
        if n==self.index:return self.frame.copy()
        if n < self.index or n-self.index>15: self.cap.set(cv2.CAP_PROP_POS_FRAMES,n)
        else:
            for _ in range(n-self.index-1): self.cap.grab()
        ok,frame=self.cap.read()
        if not ok: raise RuntimeError(f'无法读取帧 {n}')
        self.frame=cv2.cvtColor(frame,cv2.COLOR_BGR2RGB);self.index=n
        return self.frame.copy()

def sanitize(frame,kind):
    # 所有遮挡均为真实路径所在行；保留任务结果和进度。
    h,w=frame.shape[:2]
    if kind=='queue':
        for a,b in [(397,436),(585,624)]:
            cv2.rectangle(frame,(558,a),(w-24,b),(44,44,43),-1)
    if kind=='works': cv2.rectangle(frame,(143,70),(w-30,101),(22,22,22),-1)
    return frame

def crop_smooth(frame,kind,p):
    h,w=frame.shape[:2]
    focus={
      'source':(155,84,755,491),'preview':(925,67,385,485),'scrub':(925,295,385,265),
      'options':(929,60,429,505),'generate':(528,448,696,196),
      'queue':(147,90,1210,370),'works':(150,170,800,430),'persona':(155,111,400,430),
      'film':(int(w*.21),int(h*.14),int(w*.57),int(h*.72)),
    }
    x,y,cw,ch=focus[kind]
    # 缓动推近并轻微平移，所有画面仍来自逐帧实录。
    ease=bezier(p);zoom=1+0.045*ease
    nw,nh=int(cw/zoom),int(ch/zoom)
    x=int(x+(cw-nw)*0.5);y=int(y+(ch-nh)*0.5)
    x=max(0,min(w-nw,x));y=max(0,min(h-nh,y))
    return frame[y:y+nh,x:x+nw]

def place(canvas,frame,box,fill=False):
    x,y,w,h=box; ih,iw=frame.shape[:2]
    scale=max(w/iw,h/ih) if fill else min(w/iw,h/ih)
    nw,nh=max(1,round(iw*scale)),max(1,round(ih*scale))
    resized=cv2.resize(frame,(nw,nh),interpolation=cv2.INTER_AREA if scale<1 else cv2.INTER_CUBIC)
    if fill:
        ox=(nw-w)//2;oy=(nh-h)//2;canvas[y:y+h,x:x+w]=resized[oy:oy+h,ox:ox+w]
    else:
        ox=x+(w-nw)//2;oy=y+(h-nh)//2;canvas[oy:oy+nh,ox:ox+nw]=resized

def text(draw,xy,value,size,fill='white',bold=False):
    draw.text(xy,value,font=font(size,bold),fill=fill)

def background(ch,vertical):
    size=(1080,1920) if vertical else (1920,1080)
    im=Image.new('RGB',size,BG);d=ImageDraw.Draw(im)
    if vertical:
        text(d,(58,70),'易容 Studio',34,PEACH,True)
        text(d,(58,139),ch['title'] if len(ch['title'])<=15 else '三步走完换脸流程',53,bold=True)
        text(d,(58,220),ch['sub'] if len(ch['sub'])<=23 else '作品管理 · 人物形象 · 随时复用',27,(170,171,177))
        d.rounded_rectangle((58,294,397,344),radius=24,fill=(43,39,35))
        text(d,(80,304),'AI 换脸演示 · 实机录屏',23,PEACH)
        d.rounded_rectangle((42,388,1038,868),radius=22,fill=(34,35,39),outline=(65,65,68),width=2)
        text(d,(58,906),'操作细节',23,PEACH)
        d.rounded_rectangle((42,956,1038,1546),radius=22,fill=(34,35,39),outline=(65,65,68),width=2)
        text(d,(58,1770),'本地桌面工作台  /  快速入门',24,(142,143,150))
        text(d,(58,1820),'原创 AI 设计配音',22,(114,115,123))
    else:
        text(d,(64,30),'易容 Studio',26,PEACH,True)
        title_size=46 if len(ch['title'])>19 else 52
        text(d,(64,78),ch['title'],title_size,bold=True)
        text(d,(64,143),ch['sub'],25,(168,170,178))
        d.rounded_rectangle((1540,36,1856,81),radius=20,fill=(43,39,35))
        text(d,(1562,47),'AI 换脸演示 · 实机录屏',21,PEACH)
        d.rounded_rectangle((48,198,1872,941),radius=20,fill=(32,33,36),outline=(65,65,68),width=2)
        text(d,(64,1040),'本地桌面工作台 / 原创 AI 设计配音',18,(120,122,130))
    return np.asarray(im).copy()

def time_map(ch):
    parts=[]
    for name,a,b,kind in ch['shots']:
        for x,y in compact_span(name,a,b): parts.append({'file':name,'start':x,'end':y,'kind':kind})
    lengths=[p['end']-p['start'] for p in parts]
    # 将清除停顿后的动作安排进对应旁白章节；快放等待明确标注。
    total=sum(lengths)
    for p,l in zip(parts,lengths):p['duration']=ch['duration']*l/total
    ch['edits']=parts

def render(vertical, subtitles, duration, audio, preview=False):
    width,height=(1080,1920) if vertical else (1920,1080)
    name='易容Studio_抖音竖屏.mp4' if vertical else '易容Studio_闲鱼横屏.mp4'
    temp=ROOT/('portrait-silent.mp4' if vertical else 'landscape-silent.mp4')
    output=ROOT/name
    ffmpeg=['ffmpeg','-hide_banner','-loglevel','error','-f','rawvideo','-pix_fmt','rgb24',
       '-s',f'{width}x{height}','-r',str(FPS),'-i','pipe:0','-an','-c:v','h264_nvenc',
       '-preset','p5','-rc','vbr','-cq','20','-b:v','0','-pix_fmt','yuv420p','-movflags','+faststart','-y',str(temp)]
    process=None if preview else subprocess.Popen(ffmpeg,stdin=subprocess.PIPE,stderr=open(ROOT/'qa'/f'{name}.log','w',encoding='utf8'))
    readers={}; frames=round(duration*FPS); prior_index=-1; subindex=0; qa_stamps={0,7,17,29,43,56,66,76,82}
    for i in range(frames):
        t=i/FPS
        ci=next((j for j,c in enumerate(CHAPTERS) if c['start']<=t<c['start']+c['duration']),len(CHAPTERS)-1)
        ch=CHAPTERS[ci]; local=t-ch['start']; elapsed=0
        for shot in ch['edits']:
            if local < elapsed+shot['duration']: break
            elapsed+=shot['duration']
        progress=max(0,min(1,(local-elapsed)/shot['duration']))
        # 保持关键操作方向：缓动影响镜头，源视频按压缩时间连续播放。
        source_t=shot['start']+(shot['end']-shot['start'])*progress
        if shot['file'] not in readers:readers[shot['file']]=Reader(RAW/shot['file'])
        frame=sanitize(readers[shot['file']].get(source_t),shot['kind'])
        if ci!=prior_index:base=background(ch,vertical);prior_index=ci
        canvas=base.copy()
        detail=crop_smooth(frame,shot['kind'],progress)
        if vertical:
            place(canvas,frame,(54,400,972,456))
            place(canvas,detail,(54,968,972,566))
        else:
            # 每隔数秒切到细节视角；推近的幅度由真实三次贝塞尔控制。
            use_detail=shot['kind'] in ('options','works','persona') or (shot['kind']=='preview' and local>4.5)
            if use_detail:
                place(canvas,frame,(62,211,1005,716))
                place(canvas,detail,(1090,211,768,716))
            else:place(canvas,frame,(62,211,1796,716))
        im=Image.fromarray(canvas);d=ImageDraw.Draw(im)
        while subindex+1<len(subtitles) and subtitles[subindex]['end']<=t:subindex+=1
        caption=subtitles[subindex]['text'] if subtitles[subindex]['start']<=t<subtitles[subindex]['end'] else ''
        if caption:
            f=font(40 if vertical else 37,True)
            if vertical and len(caption)>17:
                a=len(caption)//2;lines=[caption[:a],caption[a:]]
            else:lines=[caption]
            for li,line in enumerate(lines):
                tw=d.textbbox((0,0),line,font=f)[2]
                d.text(((width-tw)//2,(1605 if vertical else 971)+li*57),line,font=f,fill=(246,246,247))
        if ch['id']=='generate':
            label='等待已压缩 · 非实时速度'
            pos=(62,1570) if vertical else (1450,147)
            text(d,pos,label,22,PEACH)
        # 底部进度条和章节转场闪亮线保持低干扰。
        bar_y=1870 if vertical else 1068
        d.rectangle((58,bar_y,width-58,bar_y+4),fill=(58,58,62))
        d.rectangle((58,bar_y,58+int((width-116)*t/duration),bar_y+4),fill=PEACH)
        age=local
        if age<0.42:
            x=round(width*(1-bezier(age/0.42)))
            overlay=Image.new('RGB',(width,height),BG)
            overlay.paste(im,(x,0))
            im=overlay
        if ch['id']=='outro' and local>ch['duration']-3:
            label='了解安装与使用，请查看商品说明'
            yy=1715 if vertical else 1025
            text(ImageDraw.Draw(im),(60,yy),label,24,PEACH)
        if int(t) in qa_stamps and i%FPS==0:
            im.save(ROOT/'qa'/f"{'portrait' if vertical else 'landscape'}-{int(t):02}.jpg",quality=92)
        if i==int(2.5*FPS):im.save(ROOT/('竖屏封面.jpg' if vertical else '横屏封面.jpg'),quality=95)
        if not preview:process.stdin.write(np.asarray(im).tobytes())
        if i%300==0:print(name,round(t,1),'/',round(duration,1),flush=True)
    for reader in readers.values():reader.cap.release()
    if not preview:
        process.stdin.close()
        if process.wait()!=0:raise RuntimeError(f'视频编码失败：{temp}')
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(temp),'-i',str(audio),
          '-c:v','copy','-c:a','aac','-b:a','192k','-ar','48000','-shortest','-movflags','+faststart','-y',str(output)],check=True)
        print('完成',output,flush=True)

def build(preview=False):
    audio,subtitles,duration=make_audio()
    for chapter in CHAPTERS:time_map(chapter)
    (ROOT/'剪辑工程.json').write_text(json.dumps({'fps':FPS,'duration':duration,'easing':'cubic-bezier(1/3,0,2/3,1)',
        'chapters':CHAPTERS,'subtitles':subtitles},ensure_ascii=False,indent=2),encoding='utf8')
    render(False,subtitles,duration,audio,preview)
    render(True,subtitles,duration,audio,preview)

def contact():
    samples = {
        'workflow-recovered.mp4': [80,85,90,105,140,168,172,195,205,225,244,255,270,279,283,289,310,330,342,355,375,390],
        'works.mp4': [9,14,20,28,35,45,60],
        'library.mp4': [10,18,25,35,45,65],
        'persona.mp4': [11,15,18],
        'result-playback.mp4': [0,3,6,9,12,15],
        'result-fullscreen.mp4': [0,10,20,25],
    }
    for name, stamps in samples.items():
        cap = cv2.VideoCapture(str(RAW / name))
        canvas = Image.new('RGB', (1600, math.ceil(len(stamps)/4)*225), (24,24,24))
        draw = ImageDraw.Draw(canvas)
        for i, t in enumerate(stamps):
            cap.set(cv2.CAP_PROP_POS_MSEC, t*1000)
            ok, frame = cap.read()
            if ok:
                im = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
                im.thumbnail((390,195))
                x,y = i%4*400, i//4*225
                canvas.paste(im,(x,y+26))
                draw.text((x+8,y+4),str(t),fill='white')
        canvas.save(ROOT / 'qa' / f'{Path(name).stem}-timeline.jpg')
        cap.release()

if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--contact',action='store_true');parser.add_argument('--preview',action='store_true')
    args=parser.parse_args()
    if args.contact:contact()
    else:build(args.preview)
