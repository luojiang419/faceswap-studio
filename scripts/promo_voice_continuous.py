"""整篇一次声音设计，避免每段重新采样音色；从同一波形获得字幕时间戳。"""
from pathlib import Path
import argparse
import json
import os
import sys
import types
import time
import hashlib

ROOT=Path(r'G:\app\facefusion\output\宣传片\20261024-v3')
PROJECT=Path(r'G:\app\VoxCPM-2.0.2')
SOURCE=Path(r'G:\app\facefusion\output\宣传片\20261023-v2\audio\voice-report.json')

def installed():
    import winreg
    for key in [r'Software\Microsoft\Windows\CurrentVersion\Uninstall\VoxCPMStudio',r'Software\VoxCPMStudio\Installer']:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,key) as h:
                root=Path(winreg.QueryValueEx(h,'InstallLocation')[0])
                if (root/'.voxcpm-install.json').is_file():return root
        except OSError:pass
    raise RuntimeError('没有找到正式安装资源，不下载模型。')

def setup():
    install=installed()
    os.environ.update({'VOXCPM_DATA_ROOT':str(ROOT/'voice-runtime'), 'VOXCPM_MODEL_DIR':str(install/'models/openbmb__VoxCPM2'),
      'VOXCPM_MODELS_ROOT':str(install/'models'),'VOXCPM_INSTALLED_RESOURCES_READONLY':'1','VOXCPM_OFFLINE':'1',
      'HF_HUB_OFFLINE':'1','HF_DATASETS_OFFLINE':'1','PIP_NO_INDEX':'1','VOXCPM_LAZY_STARTUP':'1'})
    package=types.ModuleType('voxcpm')
    package.__path__=[str(PROJECT/'Electron版本/backend/voxcpm'),str(PROJECT/'src/voxcpm')]
    sys.modules['voxcpm']=package
    return install

def generate():
    install=setup()
    from voxcpm.studio_app import VoxCPMStudio
    import torch
    import soundfile as sf
    segments=json.loads(SOURCE.read_text(encoding='utf8'))['segments']
    script=[{'id':s['id'],'text':s['text']} for s in segments]
    full=''.join(s['text'] for s in script)
    control='中国青年男声，普通话标准，清亮扎实的中低音，同一位专业游戏攻略讲解员，自信利落，吐字清楚，语速适中，节奏明快但不急促，全篇保持相同音色、音高和表达风格，自然讲解。'
    (ROOT/'audio').mkdir(parents=True,exist_ok=True)
    config=ROOT/'voice-runtime/config/studio_config.json';config.parent.mkdir(parents=True,exist_ok=True)
    config.write_text(json.dumps({'output_dir':str(ROOT/'audio/generated'),'disable_optimize':True,'disable_denoiser':True}),encoding='utf8')
    (ROOT/'script.json').write_text(json.dumps(script,ensure_ascii=False,indent=2),encoding='utf8')
    target=ROOT/'audio/continuous-original.wav'
    if target.exists():raise RuntimeError('已存在完整声音，请复用，避免覆盖已验收结果')
    torch.set_num_threads(4)
    torch.manual_seed(20261024);torch.cuda.manual_seed_all(20261024)
    start=time.monotonic()
    studio=VoxCPMStudio(model_dir=os.environ['VOXCPM_MODEL_DIR'])
    print('整篇一次声音设计开始，字符数',len(full),flush=True)
    result=studio.generate_audio_payload(mode='声音设计',text=full,control=control,reference_audio=None,prompt_text='',
      selected_lora='不使用 LoRA',cfg_value=2.0,normalize=False,denoise=False,inference_timesteps=16)
    rate,wav=result['audio_tuple'];sf.write(target,wav,rate)
    report={'mode':'声音设计','generationCalls':1,'referenceAudio':None,'promptAudio':None,'lora':None,
      'text':full,'control':control,'seed':20261024,'duration':len(wav)/rate,'sampleRate':rate,
      'elapsed':time.monotonic()-start,'file':str(target),'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),
      'project':str(PROJECT),'installedResources':str(install)}
    (ROOT/'audio/continuous-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(report,ensure_ascii=False),flush=True)

def align():
    install=setup()
    import torch
    from funasr import AutoModel
    torch.set_num_threads(4)
    model=AutoModel(model=str(install/'models/iic__SenseVoiceSmall'),device='cpu',disable_update=True)
    result=model.generate(input=str(ROOT/'audio/continuous-original.wav'),language='zh',use_itn=True,output_timestamp=True)[0]
    (ROOT/'audio/asr-timestamps.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(result,ensure_ascii=False),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--align',action='store_true');a=p.parse_args()
    if a.align:align()
    else:generate()
