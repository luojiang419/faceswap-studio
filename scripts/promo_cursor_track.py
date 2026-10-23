"""从未缩放的实录中匹配鼠标图形，输出镜头跟随轨迹；不重绘鼠标或伪造点击。"""
from pathlib import Path
import json
import cv2
import numpy as np
from promo_edit import Reader

ROOT=Path(r'G:\app\facefusion\output\宣传片\20261024-v3')
OLD=Path(r'G:\app\facefusion\output\宣传片\20261023-v2')
RAW=OLD/'raw'

def template():
    cap=cv2.VideoCapture(str(RAW/'take3-complete.mp4'))
    cap.set(cv2.CAP_PROP_POS_MSEC,322000);ok,frame=cap.read();cap.release()
    if not ok:raise RuntimeError('无法读取鼠标模板')
    crop=frame[173:199,457:481]
    gray=cv2.cvtColor(crop,cv2.COLOR_BGR2GRAY)
    mask=np.zeros(gray.shape,np.uint8)
    cv2.fillPoly(mask,[np.array([[2,1],[23,8],[23,14],[15,18],[11,25],[4,20]],np.int32)],255)
    cv2.imwrite(str(ROOT/'qa/cursor-match-template.png'),crop)
    return gray,mask

def find_cursor(frame,tpl,mask,prior=None):
    h,w=frame.shape[:2]
    if prior is None:x0,y0,x1,y1=0,0,w,h
    else:
        x,y=prior;x0,y0=max(0,int(x)-250),max(0,int(y)-200);x1,y1=min(w,int(x)+280),min(h,int(y)+230)
    gray=cv2.cvtColor(frame[y0:y1,x0:x1],cv2.COLOR_BGR2GRAY)
    response=cv2.matchTemplate(gray,tpl,cv2.TM_CCOEFF_NORMED,mask=mask)
    response=np.nan_to_num(response,nan=-1,posinf=-1,neginf=-1)
    candidates=[]
    for _ in range(10):
        _,score,_,loc=cv2.minMaxLoc(response)
        x,y=loc[0]+x0+4,loc[1]+y0+4
        patch=frame[max(0,y-16):min(h,y+30),max(0,x-16):min(w,x+30)].astype(np.float32)
        blue=np.maximum(0,patch[:,:,0]-np.maximum(patch[:,:,1],patch[:,:,2])).mean()
        candidates.append((score+(min(blue,25)/200),score,blue,x,y))
        lx,ly=loc;response[max(0,ly-20):ly+21,max(0,lx-20):lx+21]=-1
    # 鼠标具有黑白轮廓及实录中的蓝色定位光晕。
    valid=[c for c in candidates if c[1]>.63 and c[2]>2.5]
    if valid:
        _,score,blue,x,y=max(valid)
        return {'x':x,'y':y,'confidence':round(float(score),4),'blue':round(float(blue),2),'measured':True}
    if prior is not None:return find_cursor(frame,tpl,mask,None)
    _,score,blue,x,y=max(candidates)
    return {'x':x,'y':y,'confidence':round(float(score),4),'blue':round(float(blue),2),'measured':False}

def main():
    plan=json.loads((OLD/'剪辑工程.json').read_text(encoding='utf8'))
    requested={}
    for ch in plan['chapters']:
        for p in ch['edits']:
            requested.setdefault(p['file'],set()).update(round(t*30)/30 for t in np.arange(p['start']-.2,p['end']+.25,.125))
    requested.setdefault('take2.mp4',set()).update(round(t*30)/30 for t in np.arange(171,181,.125))
    tpl,mask=template();result={};measured=0
    for name,times in requested.items():
        cap=Reader(RAW/name);prior=None;last=-100;items=[]
        for t in sorted(times):
            if t<0:continue
            if t-last>2:prior=None
            rgb=cap.get(t);bgr=cv2.cvtColor(rgb,cv2.COLOR_RGB2BGR)
            point=find_cursor(bgr,tpl,mask,prior)
            # 低置信度点由相邻已测轨迹保持，避免镜头被文字误识别拉走。
            if point['measured']:prior=(point['x'],point['y']);measured+=1
            elif prior is not None:point['x'],point['y']=prior
            items.append({'t':round(float(t),4),**point});last=t
        cap.cap.release();result[name]=items
        print(name,len(items),'测得',sum(p['measured'] for p in items),flush=True)
    report={'templateSource':{'file':'take3-complete.mp4','time':322},'sampleRate':8,
      'measured':measured,'total':sum(map(len,result.values())),'tracks':result}
    (ROOT/'qa/cursor-tracks.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print('鼠标轨迹完成',report['measured'],report['total'],flush=True)

if __name__=='__main__':main()
