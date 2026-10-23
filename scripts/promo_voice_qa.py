"""离线回听转写，检查声音设计是否漏读或多读；不改变音频。"""
import json
import re
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from difflib import SequenceMatcher
import promo_voice as context

def main():
    from funasr import AutoModel
    model = AutoModel(model=str(context.INSTALL/'models/iic__SenseVoiceSmall'),
                      disable_update=True, device='cpu')
    report = json.loads((context.OUT/'audio/voice-report.json').read_text(encoding='utf8'))
    result = []
    clean = lambda x: re.sub(r'[^\u4e00-\u9fffA-Za-z0-9]', '', x)
    for item in report['segments']:
        heard = model.generate(input=item['path'], language='auto', use_itn=True)[0]['text'].split('|>')[-1]
        result.append({'id': item['id'], 'text': item['text'], 'recognized': heard,
                       'similarity': SequenceMatcher(None, clean(item['text']), clean(heard)).ratio()})
        print(json.dumps(result[-1], ensure_ascii=False), flush=True)
    (context.OUT/'audio/asr-qa.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf8')

if __name__ == '__main__': main()
