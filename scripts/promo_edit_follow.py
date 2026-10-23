"""鼠标跟随版：连续单声线、两组持续放大、平滑跟随与全景穿插，结尾完整界面。"""
from pathlib import Path
from difflib import SequenceMatcher
import argparse
import copy
import json
import math
import re
import subprocess
import wave
import cv2
import numpy as np
from PIL import Image,ImageDraw
import promo_edit as util
from promo_edit_fullscreen import clean as conceal_paths

ROOT=Path(r'G:\app\facefusion\output\宣传片\20261024-v3')
OLD=Path(r'G:\app\facefusion\output\宣传片\20261023-v2')
RAW=OLD/'raw'
FPS=30
SPEED=.92

def normalized(text):return ''.join(re.findall(r'[\u4e00-\u9fffA-Za-z0-9]',text))

def prepare():
    script=json.loads((ROOT/'script.json').read_text(encoding='utf8'))
    expected=''.join(normalized(s['text']) for s in script)
    asr=json.loads((ROOT/'audio/asr-timestamps.json').read_text(encoding='utf8'))
    heard=[];times=[]
    divisor=1000 if max(b for a,b in asr['timestamp'])>200 else 1
    for word,(a,b) in zip(asr['words'],asr['timestamp']):
        chars=normalized(word)
        for i,ch in enumerate(chars):
            heard.append(ch);times.append([(a+(b-a)*i/len(chars))/divisor,(a+(b-a)*(i+1)/len(chars))/divisor])
    matcher=SequenceMatcher(None,expected,''.join(heard),autojunk=False)
    if matcher.ratio()<.94:raise RuntimeError(f'全文转写匹配度不足，需检查遗漏：{matcher.ratio()}')
    char_times=np.full((len(expected),2),np.nan)
    for a,b,size in matcher.get_matching_blocks():
        if size:char_times[a:a+size]=np.array(times[b:b+size])
    valid=np.flatnonzero(~np.isnan(char_times[:,0]))
    for column in [0,1]:char_times[:,column]=np.interp(np.arange(len(expected)),valid,char_times[valid,column])
    char_times/=SPEED
    audio=ROOT/'旁白_全篇单次声音设计.wav'
    if not audio.exists():
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(ROOT/'audio/continuous-original.wav'),
          '-af',f'atempo={SPEED},loudnorm=I=-16:TP=-1.5:LRA=9,apad=pad_dur=0.7','-ar','48000','-ac','1',
          '-c:a','pcm_s16le','-y',str(audio)],check=True)
    with wave.open(str(audio),'rb') as reader:duration=reader.getnframes()/reader.getframerate()
    duration=math.ceil(duration*FPS)/FPS
    prior=json.loads((OLD/'剪辑工程.json').read_text(encoding='utf8'))['chapters']
    chapters=copy.deepcopy(prior);offset=0;offsets=[]
    for s in script:offsets.append(offset);offset+=len(normalized(s['text']))
    bounds=[0]+[(char_times[o-1,1]+char_times[o,0])/2 for o in offsets[1:]]+[duration]
    subtitles=[]
    for i,(ch,s) in enumerate(zip(chapters,script)):
        old_duration=ch['duration'];ch.update(start=bounds[i],duration=bounds[i+1]-bounds[i],text=s['text'])
        for shot in ch['edits']:shot['duration']*=ch['duration']/old_duration
        if ch['id']=='outro':
            # 最后回到真实工作台全景；不以人物特写或放大菜单结束。
            ch['edits']=[{'file':'take2.mp4','start':176,'end':180,'kind':'preview','duration':ch['duration']}]
        local_index=offsets[i]
        for phrase in re.split(r'[，。！？；：]',s['text']):
            phrase=phrase.strip()
            if not phrase:continue
            pieces=[]
            while len(phrase)>20:
                cut=phrase.rfind('、',0,19)
                cut=cut+1 if cut>7 else 17
                pieces.append(phrase[:cut].rstrip('、'));phrase=phrase[cut:].lstrip('、')
            if phrase:pieces.append(phrase)
            for text in pieces:
                length=len(normalized(text));a=local_index;b=a+length-1
                subtitles.append({'start':float(char_times[a,0]),'end':float(char_times[b,1]+.12),'text':text})
                local_index+=length
    for i in range(len(subtitles)-1):subtitles[i]['end']=min(subtitles[i]['end'],subtitles[i+1]['start']-.015)
    def timestamp(t):
        value=max(0,round(t*1000));h,value=divmod(value,3600000);m,value=divmod(value,60000);s,ms=divmod(value,1000)
        return f'{h:02}:{m:02}:{s:02},{ms:03}'
    (ROOT/'字幕.srt').write_text('\n\n'.join(f"{i+1}\n{timestamp(s['start'])} --> {timestamp(s['end'])}\n{s['text']}" for i,s in enumerate(subtitles)),encoding='utf8')
    (ROOT/'文案.txt').write_text('\n\n'.join(s['text'] for s in script),encoding='utf8')
    (ROOT/'audio/alignment-report.json').write_text(json.dumps({'similarity':matcher.ratio(),'expectedCharacters':len(expected),
      'recognizedCharacters':len(heard),'singleContinuousWaveform':True,'chapterConcatenation':False,'globalTempo':SPEED,
      'chapterBoundaries':bounds},ensure_ascii=False,indent=2),encoding='utf8')
    return audio,chapters,subtitles,duration

def source_at(chapters,t):
    ch=next((c for c in chapters if c['start']<=t<c['start']+c['duration']),chapters[-1])
    local=t-ch['start'];elapsed=0
    for shot in ch['edits']:
        if local<elapsed+shot['duration']:break
        elapsed+=shot['duration']
    p=min(1,max(0,(local-elapsed)/shot['duration']))
    return ch,shot,shot['start']+(shot['end']-shot['start'])*p

def build_camera(chapters,duration):
    raw=json.loads((ROOT/'qa/cursor-tracks.json').read_text(encoding='utf8'))
    tracks={name:np.array([[p['t'],p['x'],p['y'],p['measured']] for p in points],float) for name,points in raw['tracks'].items()}
    by_id={c['id']:c for c in chapters}
    groups=[(by_id['preview']['start']+.65,by_id['options']['start']+by_id['options']['duration']-1.2,1.48),
            (by_id['works']['start']+.35,by_id['works']['start']+by_id['works']['duration']-.6,1.65)]
    cx,cy=960.,540.;portrait_cx=960.;vx=vy=pvx=0.;path=[]
    for i in range(round(duration*FPS)):
        t=i/FPS;ch,shot,st=source_at(chapters,t);data=tracks[shot['file']]
        point=(np.interp(st,data[:,0],data[:,1]),np.interp(st,data[:,0],data[:,2]))
        zoom=1.
        for a,b,z in groups:
            if a<=t<=b:
                envelope=min(util.bezier((t-a)/.95),util.bezier((b-t)/1.05))
                zoom=1+(z-1)*envelope
        cw,chh=1920/zoom,1080/zoom
        if zoom>1.005:
            dx,dy=point[0]-cx,point[1]-cy
            # 安全区内不追逐微小抖动；跨区时按弹性阻尼平移，不重置缩放。
            tx=cx+math.copysign(max(0,abs(dx)-cw*.16),dx)
            ty=cy+math.copysign(max(0,abs(dy)-chh*.16),dy)
            # 有加速度与速度上限的临界阻尼弹簧，避免鼠标跨区后第一帧突然猛移。
            ax=max(-1800,min(1800,25*(tx-cx)-10*vx))
            ay=max(-1400,min(1400,25*(ty-cy)-10*vy))
            vx=max(-600,min(600,vx+ax/FPS));vy=max(-450,min(450,vy+ay/FPS))
            cx+=vx/FPS;cy+=vy/FPS
        else:vx=vy=0
        bx=min(1920-cw/2,max(cw/2,cx));by=min(1080-chh/2,max(chh/2,cy))
        if bx!=cx:vx=0
        if by!=cy:vy=0
        cx,cy=bx,by
        portrait_target=point[0]
        if shot['kind'] in ('preview','clip','options'):portrait_target=max(1460,portrait_target)
        if shot['kind']=='rename':portrait_target=960
        pa=max(-2200,min(2200,36*(portrait_target-portrait_cx)-12*pvx))
        pvx=max(-700,min(700,pvx+pa/FPS));portrait_cx+=pvx/FPS
        path.append({'t':t,'zoom':zoom,'cx':cx,'cy':cy,'cursorX':point[0],'cursorY':point[1],
                     'portraitCx':portrait_cx,'file':shot['file'],'sourceTime':st,'kind':shot['kind'],'chapter':ch['id']})
    audit={'zoomGroups':[{'start':a,'end':b,'zoom':z} for a,b,z in groups],
      'zoomInCount':len(groups),'fullViewPercent':100*sum(p['zoom']<1.01 for p in path)/len(path),
      'last3SecondsFull':all(p['zoom']==1 for p in path[-90:]),'cursorMeasured':raw['measured'],'cursorSamples':raw['total'],
      'cursorRedrawn':False,'sourceRecordingRepeated':False}
    audit['maxCenterStepPixels']=max(max(abs(path[i]['cx']-path[i-1]['cx']),abs(path[i]['cy']-path[i-1]['cy'])) for i in range(1,len(path)))
    assert audit['maxCenterStepPixels'] < 25
    assert audit['last3SecondsFull'] and audit['zoomInCount']==2
    (ROOT/'qa/camera-audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf8')
    (ROOT/'qa/camera-path.json').write_text(json.dumps(path,ensure_ascii=False),encoding='utf8')
    return path,audit

def draw_text(im,t,chapters,subtitles,vertical):
    d=ImageDraw.Draw(im);w,h=im.size;ch=source_at(chapters,t)[0]
    title=ch['title']
    if vertical and len(title)>18:title='易容 Studio · 实操入门'
    px,py=(38,120) if vertical else (155,8)
    ft=util.font(31 if vertical else 23,True);tw=d.textbbox((0,0),title,font=ft)[2]
    d.rounded_rectangle((px-12,py-4,min(w-22,px+tw+14),py+43),radius=10,fill=(24,25,27))
    d.text((px,py),title,font=ft,fill=util.PEACH)
    if vertical:
        d.text((38,181),'AI 换脸演示 · 实机录屏',font=util.font(23),fill=(216,218,222))
    else:
        d.rounded_rectangle((1588,8,1905,45),radius=10,fill=(24,25,27))
        d.text((1600,13),'AI 换脸演示 · 实机录屏',font=util.font(21),fill=(237,238,240))
    cap=next((s['text'] for s in subtitles if s['start']<=t<s['end']),'')
    if cap:
        ft=util.font(38 if vertical else 35,True)
        lines=[cap] if not vertical or len(cap)<=20 else [cap[:len(cap)//2],cap[len(cap)//2:].lstrip('、，')]
        for k,line in enumerate(lines):
            tw=d.textbbox((0,0),line,font=ft)[2];x=(w-tw)//2;y=(1640 if vertical else 963)+52*k
            d.rounded_rectangle((x-18,y-6,x+tw+18,y+49),radius=10,fill=(17,18,20));d.text((x,y),line,font=ft,fill='white')
    if ch['id']=='generate':d.text((38 if vertical else 1380,1555 if vertical else 58),'等待已压缩 · 非实时速度',font=util.font(23),fill=util.PEACH)
    if ch['id']=='outro' and t>ch['start']+ch['duration']-3:
        y=1815 if vertical else 1018
        d.rectangle((0,y-6,w,h),fill=(20,21,23))
        d.text((38,y),'易容 Studio · 查看商品说明，了解安装与使用',font=util.font(26 if vertical else 24),fill=util.PEACH)
    return im

def frame_at(i,path,readers,vertical):
    p=path[i]
    if p['file'] not in readers:readers[p['file']]=util.Reader(RAW/p['file'])
    frame=conceal_paths(readers[p['file']].get(p['sourceTime']),p['kind'])
    z=p['zoom']
    if not vertical:
        w,h=round(1920/z),round(1080/z)
        x=round(p['cx']-w/2);y=round(p['cy']-h/2)
        frame=cv2.resize(frame[y:y+h,x:x+w],(1920,1080),interpolation=cv2.INTER_CUBIC)
        return Image.fromarray(frame)
    # 竖版同一镜头逻辑：全景时完整界面，重点段自然展开为鼠标附近的高画幅视口。
    f=min(1,max(0,(z-1)/.48));f=util.bezier(f)
    view_w=round(1920-(1920-790)*f)
    center=960*(1-f)+p['portraitCx']*f
    x=int(max(0,min(1920-view_w,center-view_w/2)))
    display_h=round(1080*1080/view_w)
    image=cv2.resize(frame[:,x:x+view_w],(1080,display_h),interpolation=cv2.INTER_CUBIC)
    canvas=np.empty((1920,1080,3),np.uint8);canvas[:]=(18,19,22)
    y=(1920-display_h)//2
    canvas[y:y+display_h]=image
    return Image.fromarray(canvas)

def render(vertical,audio,chapters,subs,path,preview=False):
    readers={};name='易容Studio_鼠标跟随_统一男声_竖屏版.mp4' if vertical else '易容Studio_鼠标跟随_统一男声_全屏教程.mp4'
    if preview:
        samples=[c['start']+min(2,c['duration']/2) for c in chapters]
        samples += [chapters[-1]['start']+chapters[-1]['duration']-1]
        for j,t in enumerate(samples):
            i=min(len(path)-1,round(t*FPS));im=draw_text(frame_at(i,path,readers,vertical),t,chapters,subs,vertical)
            im.save(ROOT/'qa'/f"{'vertical' if vertical else 'full'}-{j:02}.jpg",quality=94)
    else:
        width,height=(1080,1920) if vertical else (1920,1080);temp=ROOT/f"{'portrait' if vertical else 'full'}-silent.mp4"
        with (ROOT/'qa'/f'{name}.log').open('w',encoding='utf8') as log:
            encoder=subprocess.Popen(['ffmpeg','-hide_banner','-loglevel','error','-f','rawvideo','-pix_fmt','rgb24','-s',f'{width}x{height}',
              '-r',str(FPS),'-i','pipe:0','-an','-c:v','h264_nvenc','-preset','p5','-rc','vbr','-cq','19','-b:v','0',
              '-pix_fmt','yuv420p','-movflags','+faststart','-y',str(temp)],stdin=subprocess.PIPE,stderr=log)
            for i,p in enumerate(path):
                im=draw_text(frame_at(i,path,readers,vertical),p['t'],chapters,subs,vertical)
                encoder.stdin.write(np.asarray(im).tobytes())
                if i%600==0:print(name,round(p['t'],1),'/',len(path)/FPS,flush=True)
                if i==75:im.save(ROOT/('竖屏封面.jpg' if vertical else '横屏封面.jpg'),quality=95)
            encoder.stdin.close()
            if encoder.wait():raise RuntimeError('编码失败')
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-i',str(temp),'-i',str(audio),'-c:v','copy','-c:a','aac',
          '-b:a','192k','-shortest','-movflags','+faststart','-y',str(ROOT/name)],check=True)
        print('完成',name,flush=True)
    for r in readers.values():r.cap.release()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--preview',action='store_true');parser.add_argument('--portrait-only',action='store_true');args=parser.parse_args()
    audio,chapters,subtitles,duration=prepare();path,audit=build_camera(chapters,duration)
    (ROOT/'剪辑工程.json').write_text(json.dumps({'fps':FPS,'duration':duration,'chapters':chapters,'subtitles':subtitles,
      'camera':audit,'audio':str(audio),'singleContinuousVoice':True},ensure_ascii=False,indent=2),encoding='utf8')
    if not args.portrait_only:render(False,audio,chapters,subtitles,path,args.preview)
    render(True,audio,chapters,subtitles,path,args.preview)
