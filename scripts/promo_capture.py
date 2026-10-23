"""有时限、可恢复的 1080p 全屏实操录屏；真实桌面捕获。"""
from pathlib import Path
import argparse
import json
import subprocess
import time

ROOT = Path(r'G:\app\facefusion\output\宣传片\20261023-v2')

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--name',default='workflow')
    parser.add_argument('--duration',type=int,default=300)
    args=parser.parse_args()
    target=ROOT/'raw'/f'{args.name}.mp4'
    if target.exists(): raise SystemExit('录屏文件已存在，避免覆盖，请使用新名称')
    start=time.time()
    command=['ffmpeg','-hide_banner','-loglevel','warning','-f','gdigrab','-framerate','30','-draw_mouse','1',
      '-i','desktop','-t',str(args.duration),'-c:v','libx264','-preset','ultrafast','-crf','16',
      '-pix_fmt','yuv420p','-movflags','+frag_keyframe+empty_moov',str(target)]
    with (ROOT/'raw'/f'{args.name}.log').open('w',encoding='utf8') as log:
        process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=log,stderr=log)
        (ROOT/'raw'/f'{args.name}.json').write_text(json.dumps({'start':start,'file':str(target),'duration':args.duration,
          'pid':process.pid,'capture':'desktop','resolution':'1920x1080'},indent=2),encoding='utf8')
        print('recording',target,flush=True)
        stop=ROOT/'raw'/f'{args.name}.stop'
        while process.poll() is None:
            if stop.exists():
                process.stdin.write(b'q\n')
                process.stdin.flush()
                process.wait(timeout=20)
                break
            time.sleep(0.2)
        if process.returncode:raise SystemExit(process.returncode)
