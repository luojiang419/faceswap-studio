"""宣传片声音设计：复用用户指定 VoxCPM 源码和已安装模型，禁止克隆输入。"""
from pathlib import Path
import json
import os
import sys
import types
import time
import faulthandler

faulthandler.enable()
faulthandler.dump_traceback_later(60, repeat=True)
print('启动声音设计', flush=True)

ROOT = Path(r'G:\app\VoxCPM-2.0.2')
OUT = Path(r'G:\app\facefusion\output\宣传片\20261023-v2')
INSTALL = Path(r'D:\Program Files\VoxCPMStudio')
os.environ.update({
    'VOXCPM_DATA_ROOT': str(OUT / 'voice-runtime'),
    'VOXCPM_MODELS_ROOT': str(INSTALL / 'models'),
    'VOXCPM_MODEL_DIR': str(INSTALL / 'models/openbmb__VoxCPM2'),
    'VOXCPM_INSTALLED_RESOURCES_READONLY': '1',
    'VOXCPM_OFFLINE': '1', 'HF_HUB_OFFLINE': '1',
    'HF_DATASETS_OFFLINE': '1', 'PIP_NO_INDEX': '1',
    'VOXCPM_LAZY_STARTUP': '1', 'PYTHONUTF8': '1',
})
package = types.ModuleType('voxcpm')
package.__path__ = [str(ROOT / 'Electron版本/backend/voxcpm'), str(ROOT / 'src/voxcpm')]
sys.modules['voxcpm'] = package
from voxcpm.studio_app import VoxCPMStudio
print('已导入工作台', flush=True)
import torch
print('已导入 torch', flush=True)
import soundfile as sf
import numpy as np

CONTROL = '中国青年男声，普通话标准，音色清亮扎实，中低音，有磁性，专业游戏攻略解说风格，自信利落，节奏明快，吐字清晰自然，重点明确，有适度热情，避免喊叫，避免播音腔。'
SCRIPT = [
    ('intro', '一张人脸，一段视频，换脸创作怎么上手？打开易容工作台，跟着这个真实案例，快速走完一遍。'),
    ('source', '第一步，准备素材。先把软件切到全屏。左侧放人脸参考，中间放待换脸视频。这个案例提前裁掉了开头空镜，导入就能直接看到人物。'),
    ('preview', '第二步，先看预览。拖动预览帧，找到人物正脸，松手后生成当前帧预览。划像对比五官、肤色和边缘，确认效果。'),
    ('clip', '只想处理一小段？把当前帧设为入点，再设出点，也能拖动区间两端。生成时只处理选中的片段，点击全片就能恢复。'),
    ('options', '需要微调？展开右侧参数面板，按需要调整换脸模型和遮罩。新手先用当前设置，别一次改太多；每次调整后，重新预览确认。'),
    ('generate', '第三步，点击立即生成。任务进度在生成队列里查看。这里压缩了实际等待时间，生成速度会随显卡、模型和片段长度变化。'),
    ('result', '完成后，直接在队列里播放输出，对照原视频检查效果。双击可以放大查看，让细节判断更直观。'),
    ('works', '人物库点击省略号，可以编辑名称、查看图片、使用、打开目录或删除。作品管理集中保存结果，可以预览、下载和打开文件位置。'),
    ('outro', '记住这三步：准备素材，预览确认，生成查看。易容工作台，把本地换脸流程放进一个桌面界面。想了解安装和使用，查看商品说明。'),
]

def main():
    (OUT / 'audio').mkdir(parents=True, exist_ok=True)
    config = OUT / 'voice-runtime/config/studio_config.json'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps({'output_dir': str(OUT / 'audio/generated'), 'disable_optimize': True,
        'disable_denoiser': True}, ensure_ascii=False), encoding='utf8')
    studio = VoxCPMStudio(model_dir=os.environ['VOXCPM_MODEL_DIR'])
    print('已初始化工作台', flush=True)
    report = {'mode': '声音设计', 'referenceAudio': None, 'promptText': '', 'control': CONTROL,
              'seed': 20261023, 'sourceProject': str(ROOT), 'segments': []}
    for key, text in SCRIPT:
        target = OUT / 'audio' / f'{key}.wav'
        start = time.monotonic()
        if not target.exists():
            torch.manual_seed(20261023)
            if torch.cuda.is_available():
                torch.cuda.manual_seed_all(20261023)
            result = studio.generate_audio_payload(mode='声音设计', text=text, control=CONTROL,
                reference_audio=None, prompt_text='', selected_lora='不使用 LoRA', cfg_value=2.0,
                normalize=False, denoise=False, inference_timesteps=16)
            rate, wave = result['audio_tuple']
            sf.write(target, wave, rate)
        data, rate = sf.read(target)
        item = {'id':key, 'text':text, 'path':str(target), 'duration':len(data)/rate,
                'sampleRate':rate, 'peak':float(np.max(np.abs(data))), 'elapsed':time.monotonic()-start}
        report['segments'].append(item)
        (OUT / 'audio/voice-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
        print(json.dumps(item,ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
