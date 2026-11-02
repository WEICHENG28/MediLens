"""Run from an extracted, trusted MediLens update package. Never reads .env."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime


def fingerprint(path, data):
    if path.endswith('.py'):
        try:
            tree = ast.parse(data.decode('utf-8'))
        except (UnicodeDecodeError, SyntaxError):
            return 'unrecognized:' + hashlib.sha256(data).hexdigest()
        if tree.body and isinstance(tree.body[0], ast.Expr) and isinstance(tree.body[0].value, ast.Constant) and isinstance(tree.body[0].value.value, str):
            tree.body.pop(0)
        if path.endswith('/chat.py'):
            # The update intentionally replaces earlier assistant prompt edits.
            for node in tree.body:
                if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'SYSTEM_PROMPT' for t in node.targets):
                    node.value = ast.Constant('PROMPT_REPLACED_BY_THIS_UPDATE')
        # Python 3.12+ adds empty type_params fields to functions/classes.
        # Exclude only empty additions; retain actual generic declarations.
        def stable(node):
            if isinstance(node, ast.AST):
                return [type(node).__name__, [[key, stable(value)]
                    for key, value in ast.iter_fields(node)
                    if not (key == 'type_params' and not value)]]
            if isinstance(node, list):
                return [stable(value) for value in node]
            if node is None or isinstance(node, (str, int, float, bool)):
                return node
            return [type(node).__name__, repr(node)]
        data = json.dumps(stable(tree), ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', type=Path, default=Path.home() / 'medilens')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    root = args.project.resolve()
    package = Path(__file__).resolve().parent
    manifest = json.loads((package / 'manifest.json').read_text())
    python = root / 'backend/.venv/bin/python'
    if not python.exists() or not (root / 'backend/app/main.py').is_file():
        sys.exit('未找到服务器项目或 Python 环境，请确认 --project 路径。未修改任何文件。')
    changed = []
    blocked = []
    for name, entry in manifest.items():
        rel = Path(name)
        if rel.is_absolute() or '..' in rel.parts or not name.startswith('backend/app/') or rel.suffix not in ('.py', '.yaml'):
            sys.exit('更新包路径不合法，已停止。')
        source = package / 'payload' / rel
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != entry['sha256']:
            sys.exit('更新包校验失败，已停止。')
        dest = root / rel
        if not dest.resolve().is_relative_to(root) or dest.is_symlink():
            sys.exit('检测到异常文件路径，已停止。')
        if dest.exists() and dest.read_bytes() == data:
            print(name, '已最新')
            continue
        if dest.exists() and fingerprint(name, dest.read_bytes()) not in entry['allowed']:
            blocked.append(name)
            print(name, '存在未识别的改动；未覆盖')
        else:
            changed.append((source, dest, data))
            print(name, '可以更新')
    if blocked:
        sys.exit('请将上述检查结果发回，先核对组员改动。所有项目文件均未修改。')
    if not args.apply:
        print('检查通过，尚未修改。执行同一命令并加 --apply 才会更新。')
        return
    if not changed:
        print('本更新已安装。')
        return
    # Validate a temporary copy before touching the running project.
    with tempfile.TemporaryDirectory(prefix='medilens-update-check-') as tmp:
        stage = Path(tmp) / 'backend'
        shutil.copytree(root / 'backend/app', stage / 'app', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        for source, dest, data in changed:
            target = stage / dest.relative_to(root / 'backend')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        env = dict(os.environ, API_TOKEN='', LLM_PROVIDER='mock', PYTHONPATH=str(stage))
        result = subprocess.run([str(python), '-m', 'pytest', str(package / 'checks'), '-q'],
                                cwd=stage, env=env, capture_output=True, text=True)
        if result.returncode:
            (package / 'validation-result.txt').write_text(result.stdout + result.stderr)
            sys.exit('临时副本测试未通过；项目未修改。测试结果保存在更新目录 validation-result.txt。')
        print('临时副本离线测试通过。')
    backup = root / 'backups' / ('server-update-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    backup.mkdir(parents=True)
    records = []
    for source, dest, data in changed:
        rel = dest.relative_to(root)
        existed = dest.exists()
        records.append({'path': str(rel), 'existed': existed})
        if existed:
            saved = backup / rel
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(dest, saved)
    (backup / 'files.json').write_text(json.dumps(records, ensure_ascii=False, indent=2))
    try:
        for source, dest, data in changed:
            dest.parent.mkdir(parents=True, exist_ok=True)
            mode = dest.stat().st_mode & 0o777 if dest.exists() else 0o644
            with tempfile.NamedTemporaryFile(dir=dest.parent, delete=False) as stream:
                stream.write(data)
                temp = Path(stream.name)
            temp.chmod(mode)
            temp.replace(dest)
    except Exception:
        for record in records:
            dest = root / record['path']
            if record['existed']:
                shutil.copy2(backup / record['path'], dest)
            else:
                dest.unlink(missing_ok=True)
        raise
    print('更新已保存。备份目录：', backup)
    print('未读取或修改 .env；未自动重启服务。')
    print('下一步在项目目录运行：bash scripts/server-run.sh')


if __name__ == '__main__':
    main()
