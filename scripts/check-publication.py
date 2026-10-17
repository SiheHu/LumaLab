#!/usr/bin/env python3
"""Fast, offline checks for the public source tree (not an image-quality test)."""
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
for name in ['LICENSE', 'README.md', 'README.zh-CN.md', 'CREDITS.md',
             'THIRD_PARTY_NOTICES.md', 'MODEL_LICENSES.md', 'CONTRIBUTING.md']:
    assert (root / name).is_file(), name
manifest = json.loads((root / 'Resources/AutoMasks/MODELS.json').read_text())
assert len({m['file'] for m in manifest['models']}) == len(manifest['models'])
for model in manifest['models']:
    assert re.fullmatch(r'[0-9a-f]{64}', model['sha256']), model['file']
    assert model['source'].startswith('https://'), model['file']
    assert (root / 'Resources/AutoMasks' / model['licenseFile']).is_file()
face = next(m for m in manifest['models'] if m['file'].startswith('face-parsing'))
assert face['optional'] and face['defaultDownload'] is False
assert 'main/' not in next(m for m in manifest['models'] if m['file']=='selfie-skin.onnx')['source']
ET.parse(root / 'docs/assets/overview.svg')
catalog = json.loads((root / 'Resources/localization-en.json').read_text())
assert catalog['所有皮肤'] == 'All Skin'
assert '默认跟随系统；可分别设置每台电脑的界面语言。' in catalog
subprocess.run(['python3', str(root / 'scripts/localize-ui.py'), '--check'], check=True, cwd=root)
if (root / '.git').is_dir():
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
    forbidden = re.compile(r'^(work/|dist/|\.build/|\.dependencies/|docs/evidence/)|\.(onnx|dylib|luma|luma\.json|jpe?g|dng|pem|p12)$', re.I)
    sensitive = re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)')
    for name in filter(None, tracked):
        assert not forbidden.search(name), 'Excluded material is tracked: ' + name
        data = (root / name).read_bytes()
        assert len(data) < 10 * 1024 * 1024, 'Unexpected large tracked file: ' + name
        assert not sensitive.search(data), 'Credential-like content: ' + name
        assert not re.search(rb'/Users/[A-Za-z0-9_.-]+/', data), 'Private developer path: ' + name
        if name.endswith('.md') and not name.startswith('Vendor/'):
            for target in re.findall(r'\]\(([^)]+)\)', data.decode('utf-8')):
                if '://' in target or target.startswith('#') or target.startswith('mailto:'):
                    continue
                local = target.split('#')[0]
                assert not local or (root / name).parent.joinpath(local).exists(), f'Broken local link in {name}: {target}'
print('Public source checks passed: licenses, manifest, localization, artwork and tracked-file boundary.')
