"""将已确认的图标同步到所有构建入口，避免各端重新使用旧品牌资源。"""

from pathlib import Path
import argparse
import hashlib
import io
import json

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'design/launcher-wireframe-icons'
FLUTTER = ROOT / 'faceswap studio/flutter_app'


def resources():
    copies = {
        ROOT / 'facefusion.ico': SOURCE / 'faceswap-studio.ico',
        ROOT / 'installer/assets/app-mark.png': SOURCE / 'png/icon-256.png',
        FLUTTER / 'windows/runner/resources/app_icon.ico': SOURCE / 'faceswap-studio.ico',
        FLUTTER / 'assets/branding/studio-mark.png': SOURCE / 'png/icon-256.png',
        FLUTTER / 'assets/branding/studio-mark-animated.webp': SOURCE / 'icon-animated.webp',
        FLUTTER / 'web/favicon.png': SOURCE / 'png/icon-32.png',
        FLUTTER / 'web/icons/Icon-192.png': SOURCE / 'png/icon-192.png',
        FLUTTER / 'web/icons/Icon-512.png': SOURCE / 'png/icon-512.png',
    }
    expected = {target: source.read_bytes() for target, source in copies.items()}
    # Maskable 图标将完整标志收进中心安全区，维持透明底。
    for size in (192, 512):
        canvas = Image.new('RGBA', (size, size))
        with Image.open(SOURCE / 'icon-master.png') as original:
            dimension = round(size * .75)
            mark = original.resize((dimension, dimension), Image.Resampling.LANCZOS)
            canvas.alpha_composite(mark, ((size-dimension)//2, (size-dimension)//2))
        buffer = io.BytesIO()
        canvas.save(buffer, format='PNG')
        expected[FLUTTER / f'web/icons/Icon-maskable-{size}.png'] = buffer.getvalue()
    return expected


def sync(check=False):
    result = []
    for target, data in resources().items():
        if check:
            if not target.is_file() or target.read_bytes() != data:
                raise ValueError('品牌图标未同步：' + str(target.relative_to(ROOT)))
        elif not target.is_file() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        result.append({'path': target.relative_to(ROOT).as_posix(),
                       'sha256': hashlib.sha256(data).hexdigest()})
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    print(json.dumps(sync(args.check), ensure_ascii=False, indent=2))
