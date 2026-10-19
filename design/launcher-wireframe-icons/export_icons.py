"""复用启动器 FaceFusionArtwork 的轮廓、特征点与拓扑，生成透明图标。"""

from pathlib import Path
import io
import json
import math
import zipfile
from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
COPPER, SAGE = "#B57A52", "#899780"
POINTS = [(-25,-27),(25,-27),(-28,-7),(28,-7),(-22,18),(22,18),
          (-13,36),(13,36),(0,44),(-20,-14),(-10,-15),(10,-15),
          (20,-14),(0,-8),(-6,10),(6,10),(-12,25),(0,22),(12,25),(0,30)]
EDGES = [(0,9),(0,10),(1,11),(1,12),(2,9),(2,14),(3,12),(3,15),
         (9,10),(11,12),(10,13),(11,13),(13,14),(13,15),(14,15),
         (14,16),(15,18),(14,17),(15,17),(4,14),(5,15),(4,16),(5,18),
         (16,17),(17,18),(16,19),(18,19),(6,19),(7,19),(8,19)]
CONTOUR = [(-29,-18,-32,-57,32,-57,29,-18),
           (29,-18,32,-8,29,0,27,3),(27,3,25,25,15,42,0,46),
           (0,46,-15,42,-25,25,-27,3),(-27,3,-29,0,-32,-8,-29,-18)]
FEATURES = [(-21,-21,-17,-25,-12,-25,-8,-22),
            (8,-22,12,-25,17,-25,21,-21),
            (-20,-14,-17,-11,-13,-11,-10,-15),
            (10,-15,13,-11,17,-11,20,-14),
            (-12,25,-4,29,4,29,12,25)]
BACK = (207, 231, 3.35, -14)
FRONT = (307, 282, 3.65, 5)
SIZES = (16,20,24,32,40,48,64,96,128,192,256,512,1024)
ICO_SIZES = (16,20,24,32,40,48,64,96,128,256)


def curve(data, count=32):
    x0,y0,x1,y1,x2,y2,x3,y3 = data
    return [((1-t)**3*x0+3*(1-t)**2*t*x1+3*(1-t)*t*t*x2+t**3*x3,
             (1-t)**3*y0+3*(1-t)**2*t*y1+3*(1-t)*t*t*y2+t**3*y3)
            for t in (i/count for i in range(count+1))]


def transform(points, placement, factor=1):
    x,y,scale,angle = placement
    a=math.radians(angle)
    return [((x+scale*(px*math.cos(a)-py*math.sin(a)))*factor,
             (y+scale*(px*math.sin(a)+py*math.cos(a)))*factor)
            for px,py in points]


def contour():
    return [point for segment in CONTOUR for point in curve(segment)]


def color(value, alpha=255):
    return tuple(bytes.fromhex(value[1:]))+(alpha,)


def face(size, placement, ink, small=False, time=None):
    factor=size/512
    layer=Image.new("RGBA",(size,size))
    draw=ImageDraw.Draw(layer)
    def line(points, width, alpha=255):
        draw.line(transform(points,placement,factor),fill=color(ink,alpha),
                  width=max(1,round(width*placement[2]*factor)),joint="curve")
    if not small:
        for a,b in EDGES:
            line((POINTS[a],POINTS[b]), .68, 150)
    line(contour(),max(1.55,small*1.2))
    for segment in FEATURES:
        line(curve(segment),max(1.35,small*.75))
    line([(0,-8),(-4,9),(0,12),(5,9)],max(1.4,small*.75))
    if not small:
        for index, (x,y) in enumerate(transform(POINTS,placement,factor)):
            radius=(1.55 if index>=9 else 1.15)*placement[2]*factor
            draw.ellipse((x-radius,y-radius,x+radius,y+radius),fill=color(ink))
    if time is not None:
        scan=Image.new("RGBA",(size,size))
        scan_draw=ImageDraw.Draw(scan)
        y=-42+86*((time*.6)%1)
        scan_draw.line(transform([(-34,y),(34,y)],placement,factor),
                       fill=color(ink,160),width=max(1,round(1.1*placement[2]*factor)))
        mask=Image.new("L",(size,size))
        ImageDraw.Draw(mask).polygon(transform(contour(),placement,factor),fill=255)
        scan.putalpha(ImageChops.multiply(scan.getchannel("A"),mask))
        layer.alpha_composite(scan)
    return layer


def render(size=1024, time=None):
    # 超采样消除锯齿；极小图标保留双脸轮廓和五官，主动简化网格。
    small=512/size/3.5 if size<=48 else 0
    large=size*3 if size<=512 else size*2
    image=face(large,BACK,SAGE,small)
    mask=Image.new("L",(large,large))
    ImageDraw.Draw(mask).polygon(transform(contour(),FRONT,large/512),fill=255)
    image.putalpha(ImageChops.multiply(image.getchannel("A"),ImageChops.invert(mask)))
    image.alpha_composite(face(large,FRONT,COPPER,small,time))
    particles=Image.new("RGBA",image.size)
    draw=ImageDraw.Draw(particles)
    f=large/512
    if not small:
        for index,data in enumerate(((164,76,226,12,366,25,402,112),
                                     (392,178,432,148,438,103,463,84))):
            points=curve(data,80)
            draw.line([(x*f,y*f) for x,y in points],fill=color(COPPER,90),
                      width=max(1,round(1.2*f)))
            for offset in (0,.43,.77):
                t=((time or .48)*.24+offset+index*.19)%1
                x,y=points[round(t*80)]
                r=(2.4+offset*1.8)*f
                draw.ellipse((x*f-r,y*f-r,x*f+r,y*f+r),fill=color(COPPER))
        for x,y,r in ((437,72,3),(454,127,2.4),(424,45,2)):
            draw.ellipse(((x-r)*f,(y-r)*f,(x+r)*f,(y+r)*f),fill=color(SAGE))
    image.alpha_composite(particles)
    return image.resize((size,size),Image.Resampling.LANCZOS)


def svg():
    outline="M -29 -18 "+" ".join("C "+" ".join(map(str,s[2:])) for s in CONTOUR)+" Z"
    def group(placement,ink,masked=False):
        x,y,s,a=placement
        result=[f'<g transform="translate({x} {y}) rotate({a}) scale({s})" fill="none" stroke="{ink}" stroke-linecap="round" stroke-linejoin="round">']
        result.append(f'<path d="{outline}" stroke-width="1.55"/>')
        for p,q in EDGES:
            x1,y1=POINTS[p]; x2,y2=POINTS[q]
            result.append(f'<path d="M {x1} {y1} L {x2} {y2}" stroke-opacity=".59" stroke-width=".68"/>')
        for c in FEATURES:
            result.append(f'<path d="M {c[0]} {c[1]} C '+" ".join(map(str,c[2:]))+'" stroke-width="1.35"/>')
        result.append('<path d="M 0 -8 L -4 9 L 0 12 L 5 9" stroke-width="1.4"/>')
        for index,(px,py) in enumerate(POINTS):
            result.append(f'<circle cx="{px}" cy="{py}" r="{1.55 if index>=9 else 1.15}" fill="{ink}" stroke="none"/>')
        return "\n".join(result)+"</g>"
    x,y,s,a=FRONT
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">\n'
            '<title>FaceSwap Studio 启动器线框双面具</title>\n'
            f'<defs><mask id="rear"><path fill="white" d="M0 0H512V512H0Z"/>'
            f'<path d="{outline}" transform="translate({x} {y}) rotate({a}) scale({s})" fill="black"/></mask></defs>\n'
            '<g mask="url(#rear)">'+group(BACK,SAGE)+'</g>\n'+group(FRONT,COPPER)+
            f'<g fill="none" stroke="{COPPER}" stroke-opacity=".35" stroke-width="1.2"><path d="M164 76 C226 12 366 25 402 112"/><path d="M392 178 C432 148 438 103 463 84"/></g>'+
            ''.join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{c}"/>' for x,y,r,c in
                    ((198,51,3,COPPER),(286,40,4,COPPER),(370,71,3,COPPER),
                     (421,139,3,COPPER),(447,103,3.5,COPPER),(437,72,3,SAGE),
                     (454,127,2.4,SAGE),(424,45,2,SAGE)))+'\n</svg>\n')


def export():
    ROOT.mkdir(exist_ok=True)
    output=ROOT/"png"
    output.mkdir(exist_ok=True)
    for size in SIZES:
        render(size).save(output/f"icon-{size}.png")
    master=render()
    master.save(ROOT/"icon-master.png")
    (ROOT/"icon.svg").write_text(svg(),encoding="utf-8")
    # 逐帧生成，确保 ICO 的小尺寸确实使用简化网格的版本。
    payloads=[]
    for size in ICO_SIZES:
        buffer=io.BytesIO(); render(size).save(buffer,format="PNG")
        payloads.append(buffer.getvalue())
    import struct
    offset=6+16*len(ICO_SIZES)
    directory=[]
    for size,payload in zip(ICO_SIZES,payloads):
        directory.append(struct.pack('<BBBBHHII',size%256,size%256,0,0,1,32,len(payload),offset))
        offset+=len(payload)
    (ROOT/"faceswap-studio.ico").write_bytes(struct.pack('<HHH',0,1,len(ICO_SIZES))+b''.join(directory)+b''.join(payloads))
    frames=[render(384,i/12) for i in range(40)]
    frames[0].save(ROOT/"icon-animated.webp",save_all=True,append_images=frames[1:],
                   duration=83,loop=0,lossless=True)
    font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',20)
    preview=Image.new('RGB',(1000,640))
    draw=ImageDraw.Draw(preview)
    for x,bg,ink,label in ((0,'#fbfaf7','#333333','LIGHT'),(500,'#1d1f1d','#f0ede7','DARK')):
        draw.rectangle((x,0,x+499,639),fill=bg)
        draw.text((x+32,24),label,font=font,fill=ink)
        icon=render(380); preview.paste(icon,(x+60,52),icon)
        for left,size in zip((35,100,180,280),(24,32,64,128)):
            icon=render(size); preview.paste(icon,(x+left,466+(128-size)//2),icon)
            draw.text((x+left,605),str(size),font=font,fill=ink)
    preview.save(ROOT/'preview-light-dark.png')
    report={'来源':'installer/bootstrap/Program.cs: FaceFusionArtwork',
            '透明PNG尺寸':list(SIZES),'ICO尺寸':list(ICO_SIZES),'动效帧数':40,
            '检查':[]}
    for path in [ROOT/'icon-master.png',*output.glob('*.png')]:
        with Image.open(path) as image:
            assert image.mode=='RGBA'
            low,high=image.getchannel('A').getextrema()
            assert low==0 and high>0
            assert image.getpixel((0,0))[3]==0 and image.getpixel((image.width-1,image.height-1))[3]==0
            report['检查'].append(path.relative_to(ROOT).as_posix())
    with Image.open(ROOT/'faceswap-studio.ico') as icon:
        assert sorted(s[0] for s in icon.ico.sizes())==list(ICO_SIZES)
        for size in ICO_SIZES:
            low,high=icon.ico.getimage((size,size)).getchannel('A').getextrema()
            assert low==0 and high>0
    with Image.open(ROOT/'icon-animated.webp') as animation:
        assert animation.n_frames==40
        assert animation.getchannel('A').getextrema()==(0,255)
        animation.seek(20)
        assert animation.getchannel('A').getextrema()==(0,255)
    (ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    archive=ROOT/'faceswap-studio-icons.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as package:
        for path in sorted(ROOT.rglob('*')):
            if path.is_file() and path!=archive and '__pycache__' not in path.parts:
                package.write(path,path.relative_to(ROOT))
    print('已导出：SVG、13 种透明 PNG、10 帧 ICO、40 帧透明 WebP、浅深底预览；验证通过。')


if __name__=='__main__':
    export()
