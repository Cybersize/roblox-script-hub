"""Refresh the loader's emergency registry from manifest.json; no network needed."""
from pathlib import Path
import argparse
import json

START = '-- BUNDLED_REGISTRY_BEGIN'
END = '-- BUNDLED_REGISTRY_END'

def render_registry(manifest):
    lines = ['local BUNDLED_GAMES = {']
    for place, entry in manifest['games'].items():
        q = lambda value: json.dumps(value, ensure_ascii=False)
        enabled = 'false' if entry.get('enabled') is False else 'true'
        lines.append(f'    [{q(place)}] = {{name = {q(entry["name"])}, path = {q(entry["path"])}, enabled = {enabled}}},')
    lines.append('}')
    return '\n'.join(lines)

def refresh(root, check=False):
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    path = root / 'loader.luau'
    source = path.read_text(encoding='utf-8')
    before, rest = source.split(START, 1)
    old, after = rest.split(END, 1)
    new = '\n' + render_registry(manifest) + '\n'
    if check:
        assert old == new, 'Bundled registry is stale: run python tools/build_loader.py'
    else:
        path.write_text(before + START + new + END + after, encoding='utf-8', newline='\n')
    return len(manifest['games'])

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    print(f'{"Checked" if args.check else "Bundled"} {refresh(root, args.check)} game routes.')
