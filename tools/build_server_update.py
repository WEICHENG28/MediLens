"""Create a secret-free backend update with recognized source fingerprints."""
from pathlib import Path
import hashlib
import importlib.util
import json
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ['backend/app/chat.py', 'backend/app/guard.py', 'backend/app/llm.py',
         'backend/app/knowledge.py', 'backend/app/main.py', 'backend/app/ocr_review.py',
         'backend/app/knowledge_base/kb_curated.yaml']


def build(output, reviewed=None, *, name="medilens-server-update-20261030-v2"):
    spec = importlib.util.spec_from_file_location('installer', ROOT / 'tools/server_update_install.py')
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    with tempfile.TemporaryDirectory() as temporary:
        if Path(name).name != name or name in ('', '.', '..'):
            raise ValueError('更新包名称不合法')
        package = Path(temporary) / name
        package.mkdir()
        shutil.copy2(ROOT / 'tools/server_update_install.py', package / 'install.py')
        shutil.copy2(ROOT / 'tools/diagnose_ai_review.py', package / 'diagnose_ai_review.py')
        manifest = {}
        for name in FILES:
            data = (ROOT / name).read_bytes()
            variants = [data]
            old = subprocess.run(['git', 'show', 'HEAD:' + name], cwd=ROOT, capture_output=True)
            if old.returncode == 0:
                variants.append(old.stdout)
                if name.endswith('/chat.py'):
                    for prefix in ['text and text.strip() and ', 'text and ', 'text.strip() and ']:
                        variants.append(old.stdout.replace(b'if guard.check(', ('if ' + prefix + 'guard.check(').encode()))
                if name.endswith('/guard.py'):
                    earlier = data.decode().replace('    r"肯定没事|绝对没事|保证.{0,4}(没事|康复)|不用担心|不必担心",\n', '').replace('    r"都怪你|不听话|活该",\n', '')
                    variants.append(earlier.encode())
            if reviewed and (reviewed / Path(name).name).is_file():
                # Only pass a directory whose files have been inspected first.
                variants.append((reviewed / Path(name).name).read_bytes())
            manifest[name] = {'sha256': hashlib.sha256(data).hexdigest(),
                              'allowed': sorted({installer.fingerprint(name, value) for value in variants})}
            target = package / 'payload' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (package / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        shutil.copytree(ROOT / 'backend/tests', package / 'checks', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        (package / 'README.txt').write_text(
            f'MediLens 服务端更新：{name}\n'
            '不包含 .env、访问口令、模型密钥或用户报告。\n'
            'python3 install.py --apply\n'
            '检查、临时副本离线测试通过后，才会备份及替换。\n'
            '出现未知改动时停止。看到更新已保存后再执行：\n'
            'bash ~/medilens/scripts/server-run.sh\n', encoding='utf-8')
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in package.rglob('*'):
                if path.is_file():
                    archive.write(path, path.relative_to(package.parent))


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    parser.add_argument('--reviewed', type=Path)
    parser.add_argument('--name', default='medilens-server-update-20261030-v2')
    args = parser.parse_args()
    build(args.output, args.reviewed, name=args.name)
    print('已生成更新包：', args.output)
