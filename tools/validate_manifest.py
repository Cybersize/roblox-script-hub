"""Validate the place registry and referenced script files without executing them."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
assert manifest.get('schemaVersion') == 1, 'Unsupported schemaVersion'
games = manifest.get('games')
assert isinstance(games, dict) and games, 'games must be a nonempty object'
for place_id, entry in games.items():
    assert place_id.isdigit() and int(place_id) > 0, f'Invalid place ID: {place_id}'
    assert isinstance(entry, dict), f'Invalid entry: {place_id}'
    assert isinstance(entry.get('name'), str) and entry['name'], f'Missing name: {place_id}'
    assert isinstance(entry.get('enabled'), bool), f'enabled must be boolean: {place_id}'
    path = entry.get('path', '')
    assert re.fullmatch(r'games/[A-Za-z0-9_/-]+\.luau', path), f'Invalid path: {path}'
    assert '..' not in path, f'Unsafe path: {path}'
    target = (root / path).resolve()
    assert target.is_relative_to(root / 'games'), f'Path leaves games/: {path}'
    assert target.is_file() and target.stat().st_size, f'Missing/empty script: {path}'
    assert target.stat().st_size <= 2 * 1024 * 1024, f'Script is too large: {path}'
    target.read_text(encoding='utf-8')
assert (root / 'loader.luau').is_file(), 'Missing loader'
from build_loader import refresh
refresh(root, check=True)
print(f'Validated {len(games)} registered games.')
