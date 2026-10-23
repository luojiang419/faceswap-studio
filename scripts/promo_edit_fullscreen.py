"""新版教程：原生 1080p 软件全屏实录，贝塞尔镜头，保留关键操作顺序。"""
from pathlib import Path
import argparse
import json
import math
import subprocess
import cv2
import numpy as np
from PIL import Image, ImageDraw
import promo_edit as base

ROOT=Path(r'G:\app\facefusion\output\宣传片\20261023-v2')
RAW=ROOT/'raw'
base.ROOT=ROOT
base.RAW=RAW
FPS=30
CHAPTERS=[
 {'id':'intro','title':'易容 Studio · 真实案例快速入门','shots':[('take2.mp4',173,177,'preview'),('take3.mp4',222,224.5,'film')],'weights':[4,2]},
 {'id':'source','title':'01 准备素材 · 全屏操作','shots':[('workflow.mp4',125,129,'source'),('workflow.mp4',138,141,'target')],'weights':[5,5]},
 {'id':'preview','title':'02 定位人物 · 先看预览','shots':[('workflow.mp4',160.4,164.5,'preview'),('workflow.mp4',200,203,'preview'),('take2.mp4',171,175,'preview')],'weights':[3,2,5]},
 {'id':'clip','title':'I/O 选段 · 只生成需要的片段','shots':[('workflow.mp4',256,260,'clip'),('take2.mp4',65.5,69.5,'clip'),('take2.mp4',72,74,'clip')],'weights':[3,4,3]},
 {'id':'options','title':'按需微调 · 模型与进阶控制','shots':[('take2.mp4',189.3,194,'options'),('take2.mp4',217,222,'options')],'weights':[4,8]},
 {'id':'generate','title':'03 立即生成 · 查看队列进度','shots':[('take3.mp4',126.5,132,'generate'),('take3.mp4',134,148.5,'queue')],'weights':[3,9]},
 {'id':'result','title':'完成后播放检查 · 支持全屏查看','shots':[('take3.mp4',219.5,222,'queue'),('take3.mp4',222,226,'film')],'weights':[2,5]},
 {'id':'works','title':'人物编辑与作品管理','shots':[('take3.mp4',320,324,'persona'),('take3.mp4',393,396,'rename'),('take3.mp4',410,413,'rename'),('take3.mp4',475,480,'works')],'weights':[3,1,1,4]},
 {'id':'outro','title':'准备素材 → 预览确认 → 生成查看','shots':[('workflow.mp4',135,137,'source'),('take2.mp4',172,175,'preview'),('take3.mp4',222,225,'film'),('take3.mp4',441,443,'works')],'weights':[3,3,3,3]},
]
base.CHAPTERS=CHAPTERS

def prepare():
    audio,subtitles,duration=base.make_audio()
    for ch in CHAPTERS:
        parts=[]
        for (name,a,b,kind),weight in zip(ch['shots'],ch['weights']):
            if name == 'take3.mp4': name = 'take3-complete.mp4'
            spans=base.compact_span(name,a,b)
            total=sum(y-x for x,y in spans)
            for x,y in spans:
                parts.append({'file':name,'start':x,'end':y,'kind':kind,
                  'duration':ch['duration']*weight/sum(ch['weights'])*(y-x)/total})
        ch['edits']=parts
    (ROOT/'剪辑工程.json').write_text(json.dumps({'resolution':['1920x1080','1080x1920'],'fps':FPS,
       'easing':'cubic-bezier(1/3,0,2/3,1)','duration':duration,'chapters':CHAPTERS,
       'subtitles':subtitles},ensure_ascii=False,indent=2),encoding='utf8')
    return audio,subtitles,duration

def clean(frame,kind):
    if kind in ('queue','generate'):
        # 判断顶部队列状态卡，避免在操作台错误遮住图片。
        color = np.mean(frame[128:156,172:194], axis=(0,1))
        if color[0] - color[2] > 8 and color[0] > 40:
            first_completed = np.mean(frame[310:328,1670:1690,1]) > np.mean(frame[310:328,1670:1690,2])
            for row,y in enumerate((396,584,772,960)):
                x = 558 if row or first_completed else 420
                cv2.rectangle(frame,(x,y),(1765,y+39),(34,34,33),-1)
    if kind=='works':cv2.rectangle(frame,(144,72),(1900,101),(22,22,22),-1)
    return frame

def camera(frame,kind,p,vertical):
    h,w=frame.shape[:2];ease=base.bezier(p)
    if vertical:
        center={'source':400+300*ease,'target':992,'preview':1550,'clip':1550,'options':1670,
                'generate':1515,'queue':1030,'film':960,'persona':450,'rename':960,'works':440}[kind]
        cw=round(h*9/16);x=int(max(0,min(w-cw,center-cw/2)))
        return cv2.resize(frame[:,x:x+cw],(1080,1920),interpolation=cv2.INTER_CUBIC)
    strength={'source':0.06,'target':0.18,'preview':0.28,'clip':0.40,'options':0.38,'persona':0.85,
              'rename':0.75,'works':0.55,'generate':0.03,'queue':0.02,'film':0.02}[kind]
    zoom=1+strength*ease
    cx,cy={'source':(800,520),'target':(990,530),'preview':(1490,530),'clip':(1500,800),
           'options':(1670,510),'persona':(500,340),'rename':(960,540),'works':(530,400),
           'generate':(1450,810),'queue':(1000,390),'film':(960,540)}[kind]
    cw,ch=round(w/zoom),round(h/zoom);x=int(max(0,min(w-cw,cx-cw/2)));y=int(max(0,min(h-ch,cy-ch/2)))
    return cv2.resize(frame[y:y+ch,x:x+cw],(1920,1080),interpolation=cv2.INTER_CUBIC)

def compose(t,vertical,subtitles,readers):
    ch=next((c for c in CHAPTERS if c['start']<=t<c['start']+c['duration']),CHAPTERS[-1])
    local=t-ch['start'];elapsed=0
    for shot in ch['edits']:
        if local<elapsed+shot['duration']:break
        elapsed+=shot['duration']
    p=min(1,max(0,(local-elapsed)/shot['duration']))
    if shot['file'] not in readers:readers[shot['file']]=base.Reader(RAW/shot['file'])
    f=clean(readers[shot['file']].get(shot['start']+(shot['end']-shot['start'])*p),shot['kind'])
    im=Image.fromarray(camera(f,shot['kind'],p,vertical));d=ImageDraw.Draw(im)
    width,height=im.size
    # 短阶段标签，软件占满整个画面；按钮与 I/O 区域保持可见。
    title=ch['title'] if not vertical or len(ch['title'])<=17 else '三步走完本地换脸流程'
    x,y=(38,62) if vertical else (155,8)
    title_font=base.font(31 if vertical else 23,True)
    tw=d.textbbox((0,0),title,font=title_font)[2]
    d.rounded_rectangle((x-12,y-4,min(width-24,x+tw+14),y+43),radius=12,fill=(24,25,27))
    d.text((x,y),title,font=title_font,fill=base.PEACH)
    label='AI 换脸演示 · 实机录屏'
    ly=122 if vertical else 13
    lx=38 if vertical else 1600
    d.rounded_rectangle((lx-10,ly-3,lx+(310 if vertical else 285),ly+32),radius=11,fill=(24,25,27))
    d.text((lx,ly),label,font=base.font(23 if vertical else 21),fill=(237,238,240))
    caption=next((s['text'] for s in subtitles if s['start']<=t<s['end']),'')
    if caption:
        font=base.font(38 if vertical else 35,True)
        lines=[caption]
        if vertical and len(caption)>20:lines=[caption[:len(caption)//2],caption[len(caption)//2:]]
        sy=1710 if vertical else 964
        for k,line in enumerate(lines):
            tw=d.textbbox((0,0),line,font=font)[2];sx=(width-tw)//2;yy=sy+k*52
            d.rounded_rectangle((sx-18,yy-6,sx+tw+18,yy+49),radius=10,fill=(17,18,20))
            d.text((sx,yy),line,font=font,fill=(251,251,252))
    if ch['id']=='generate':
        d.text((38 if vertical else 1370,1650 if vertical else 57),'等待已压缩 · 非实时速度',font=base.font(24),fill=base.PEACH)
    # 章节切换使用三次贝塞尔淡入，不移动整个软件导致半屏空白。
    if local<.20 and ch['id']!='intro':
        amount=base.bezier(local/.20)
        im=Image.blend(Image.new('RGB',im.size,(18,19,22)),im,.5+.5*amount)
    if ch['id']=='outro' and local>ch['duration']-2.5:
        d=ImageDraw.Draw(im);yy=1850 if vertical else 1018
        d.rectangle((0,yy-7,width,height),fill=(20,21,23))
        d.text((38,yy),'易容 Studio  ·  查看商品说明，了解安装与使用',font=base.font(28 if vertical else 24),fill=base.PEACH)
    return im

def render(vertical,audio,subtitles,duration,preview=False):
    name='易容Studio_抖音竖屏.mp4' if vertical else '易容Studio_全屏操作教程.mp4'
    temp=ROOT/('portrait-silent.mp4' if vertical else 'landscape-silent.mp4')
    width,height=(1080,1920) if vertical else (1920,1080)
    readers={}
    if preview:
        times=[c['start']+min(2,c['duration']/3) for c in CHAPTERS]
        times += [c['start']+c['duration']*.7 for c in CHAPTERS]
        for j,t in enumerate(times):compose(t,vertical,subtitles,readers).save(ROOT/'qa'/f"{'vertical' if vertical else 'full'}-{j:02}.jpg",quality=93)
    else:
        with (ROOT/'qa'/f'{name}.log').open('w',encoding='utf8') as log:
            proc=subprocess.Popen(['ffmpeg','-hide_banner','-loglevel','error','-f','rawvideo','-pix_fmt','rgb24','-s',f'{width}x{height}',
              '-r','30','-i','pipe:0','-an','-c:v','h264_nvenc','-preset','p5','-rc','vbr','-cq','19','-b:v','0','-pix_fmt','yuv420p',
              '-movflags','+faststart','-y',str(temp)],stdin=subprocess.PIPE,stderr=log)
            for i in range(round(duration*FPS)):
                im=compose(i/FPS,vertical,subtitles,readers)
                proc.stdin.write(np.asarray(im).tobytes())
                if i==75:im.save(ROOT/('竖屏封面.jpg' if vertical else '横屏封面.jpg'),quality=95)
                if i%600==0:print(name,i/FPS,'/',round(duration,1),flush=True)
            proc.stdin.close()
            if proc.wait():raise RuntimeError('视频编码失败')
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(temp),'-i',str(audio),'-c:v','copy','-c:a','aac','-b:a','192k',
            '-shortest','-movflags','+faststart','-y',str(ROOT/name)],check=True)
        print('完成',ROOT/name,flush=True)
    for reader in readers.values():reader.cap.release()

def contacts():
    ts=[126,130,138,145,149,220,222,224,280,322,350,380,395,411,441,478]
    reader=base.Reader(RAW/'take3.mp4');im=Image.new('RGB',(1600,900));d=ImageDraw.Draw(im)
    for i,t in enumerate(ts):
        f=Image.fromarray(reader.get(t));f.thumbnail((390,195));x=i%4*400;y=i//4*225;im.paste(f,(x,y+25));d.text((x+8,y+4),str(t),fill='white')
    im.save(ROOT/'qa/take3-contact.jpg');reader.cap.release()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--preview',action='store_true');p.add_argument('--contact',action='store_true');args=p.parse_args()
    if args.contact:contacts()
    else:
        audio,subs,duration=prepare();render(False,audio,subs,duration,args.preview);render(True,audio,subs,duration,args.preview)
