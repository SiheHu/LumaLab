#!/usr/bin/env python3
"""Fetch checksum-pinned optional runtime assets; never called while editing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / 'Resources/AutoMasks/MODELS.json').read_text())


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, target, expected, verify=False):
    if target.exists() and digest(target) == expected:
        print('Verified:', target.relative_to(ROOT))
        return
    if verify:
        raise RuntimeError('Missing or checksum mismatch: ' + str(target.relative_to(ROOT)))
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.download-', dir=target.parent)
    os.close(fd)
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'LumaLab-dependency-setup/1'})
        with urllib.request.urlopen(request, timeout=90) as source, open(temporary, 'wb') as destination:
            shutil.copyfileobj(source, destination, length=1024 * 1024)
        if digest(Path(temporary)) != expected:
            raise RuntimeError('SHA-256 mismatch for ' + target.name)
        os.replace(temporary, target)
        print('Downloaded and verified:', target.relative_to(ROOT))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true', help='Verify existing files without network access')
    parser.add_argument('--include-restricted-face', action='store_true',
                        help='Opt in to the separate Face Parsing weights after reviewing MODEL_LICENSES.md; not commercial clearance')
    args = parser.parse_args()
    runtime = MANIFEST['runtime']
    library = ROOT / 'Vendor/ONNXRuntime/lib' / runtime['file']
    if not (library.exists() and digest(library) == runtime['sha256BeforeAppSigning']):
        if args.verify:
            raise RuntimeError('Missing or checksum mismatch: ONNX Runtime. Only macOS arm64 assets are pinned.')
        archive = ROOT / '.dependencies/onnxruntime-osx-arm64-1.20.1.tgz'
        fetch(runtime['source'], archive, runtime['archiveSHA256'])
        # Read only the known library member; never extract arbitrary archive paths.
        member = 'onnxruntime-osx-arm64-1.20.1/lib/' + runtime['file']
        with tarfile.open(archive, 'r:gz') as bundle:
            entry = bundle.getmember(member)
            if not entry.isfile() or entry.size > 100 * 1024 * 1024:
                raise RuntimeError('Unexpected runtime archive entry')
            data = bundle.extractfile(entry).read()
        if hashlib.sha256(data).hexdigest() != runtime['sha256BeforeAppSigning']:
            raise RuntimeError('Runtime library SHA-256 mismatch')
        library.parent.mkdir(parents=True, exist_ok=True)
        temporary = library.with_suffix('.download')
        temporary.write_bytes(data)
        os.replace(temporary, library)
        library.chmod(0o755)
    else:
        print('Verified: ONNX Runtime 1.20.1 (macOS arm64)')
    for model in MANIFEST['models']:
        if model.get('optional') and not args.include_restricted_face:
            print('Skipped optional Face Parsing weights; see MODEL_LICENSES.md')
            continue
        fetch(model['source'], ROOT / 'Resources/AutoMasks' / model['file'], model['sha256'], args.verify)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(str(error))
