"""将已构建的两个安装器与验收材料打包，不修改或发布安装器。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--xnook', type=Path, required=True)
    parser.add_argument('--xisland', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xisland-inputs', type=Path, required=True)
    parser.add_argument('--xisland-license', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    reserved = {'manifest.json', 'README.md', 'Windows验收说明.md', 'Test-Suite.ps1',
                'LICENSE-XNook.txt', 'LICENSE-XIsland.txt', 'THIRD-PARTY-NOTICES.md',
                'XNook-build-inputs.json', 'XIsland-build-inputs.json'}
    reserved.update(path.name for path in (root / 'licenses').glob('*.txt'))
    names = [args.xnook.name.casefold(), args.xisland.name.casefold()]
    if names[0] == names[1] or any(name in {item.casefold() for item in reserved} for name in names):
        raise ValueError('安装器文件名与另一安装器或包内材料冲突，已停止打包')
    version = json.loads((root / 'package.json').read_text())['version']
    island_version = json.loads(args.xisland_inputs.read_text())['version']
    files = {
        args.xnook.name: args.xnook.read_bytes(),
        args.xisland.name: args.xisland.read_bytes(),
        'Windows验收说明.md': (root.parent / 'docs/windows/windows-test-checklist.md').read_bytes(),
        'Test-Suite.ps1': (root / 'scripts/Test-Suite.ps1').read_bytes(),
        'LICENSE-XNook.txt': (root.parent / 'LICENSE').read_bytes(),
        'LICENSE-XIsland.txt': args.xisland_license.read_bytes(),
        'THIRD-PARTY-NOTICES.md': (root / 'THIRD-PARTY-NOTICES.md').read_bytes(),
        'ICAL.js-LICENSE.txt': (root / 'licenses/ICAL.js-LICENSE.txt').read_bytes(),
        'XNook-build-inputs.json': (root.parent / f'.build/windows-build-inputs/{version}.json').read_bytes(),
        'XIsland-build-inputs.json': args.xisland_inputs.read_bytes(),
    }
    for license_file in sorted((root / 'licenses').glob('*.txt')):
        files[license_file.name] = license_file.read_bytes()
    for name in (args.xnook.name, args.xisland.name):
        if not files[name].startswith(b'MZ'):
            raise ValueError(f'{name} 不是 Windows 可执行文件')
    files['README.md'] = f'''# XNook + XIsland Windows 联动测试包

本包版本：XNook {version}、XIsland {island_version}。先完整解压，再安装两个 setup.exe。
首次分别运行一次，之后可用切换按钮唤起对方。使用共享手势和启动偏好时，两端都应更新到本包版本。
此包用于本机测试，未自动发布。XIsland 0.1.3 旧版不支持基本联动协议。

可先运行 Test-Suite.ps1 校验文件；该脚本不会安装、启动或修改系统配置。
真实媒体、文件操作、多屏和触控板等请按 Windows验收说明.md 逐项测试。
Windows 实机验收未完成，构建/解包结果不能代替真实运行结果。
'''.encode('utf-8')
    manifest = {
        'xnookVersion': version,
        'xislandVersion': island_version,
        'windowsRuntimeVerified': False,
        'artifacts': [{'name': name, 'bytes': len(data), 'sha256': sha256(data)} for name, data in sorted(files.items())],
    }
    files['manifest.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise FileExistsError(f'不覆盖现有交付包：{args.output}')
    with ZipFile(args.output, 'x', ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr('XNook-XIsland-Windows/' + name, data)
    with ZipFile(args.output) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP 校验失败')
        for item in manifest['artifacts']:
            if sha256(archive.read('XNook-XIsland-Windows/' + item['name'])) != item['sha256']:
                raise ValueError('包内文件哈希不一致')
    print(json.dumps({'path': str(args.output.resolve()), 'bytes': args.output.stat().st_size,
                      'sha256': sha256(args.output.read_bytes()), 'zipVerified': True}, ensure_ascii=False))


if __name__ == '__main__':
    main()
