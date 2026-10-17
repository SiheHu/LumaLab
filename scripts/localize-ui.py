#!/usr/bin/env python3
"""Idempotently adapt SwiftUI/AppKit display boundaries to the shared catalog.

Only the macOS UI target is scanned. Domain strings, stored names, operation IDs,
source paths, user-entered values and file formats are not rewritten.
Run after UI changes, then inspect its diff. --check reports pending adaptations.
"""
import re, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
# Parse balanced Swift call arguments, including interpolations/nested quotes.
def skip_string(s, i):
    i += 1
    while i < len(s):
        if s[i] == '\\':
            if i+1 < len(s) and s[i+1] == '(':
                _, i = argument(s, i+2, stop_close=True)
            else: i += 2
        elif s[i] == '"': return i+1
        else: i += 1
    return i

def argument(s, start, stop_close=False):
    depth = 0; i = start
    while i < len(s):
        c = s[i]
        if c == '"': i = skip_string(s,i); continue
        if c in '([{': depth += 1
        elif c in ')]}':
            if depth == 0: return i, i+1
            depth -= 1
        elif c == ',' and depth == 0 and not stop_close: return i, i+1
        i += 1
    return i,i

calls = r'(?<![\w])(?:Text|Button|Toggle|Picker|Label|Menu|TextField|ProgressView|CommandMenu|GroupBox|InspectorSection|\.help|\.accessibilityLabel|\.navigationTitle|\.alert|\.confirmationDialog)\s*\('
# AppKit native panels/alerts get the same adapter. Do not localize stored text.
assignments = re.compile(r'\b(?:panel\.(?:title|message|prompt)|alert\.(?:messageText|informativeText))\s*=\s*')
changes = 0
for path in sorted((root/'Sources/LumaLab').glob('*.swift')):
    if path.name.startswith('Localization') or path.name.endswith('Checks.swift'): continue
    source = path.read_text()
    # String interpolation's specifier: belongs to LocalizedStringKey, not String.
    source = source.replace('model.history[index].adjustments.exposure, specifier: "%.2f"', 'String(format: "%.2f", model.history[index].adjustments.exposure)')
    spans = []
    for match in re.finditer(calls,source):
        a=match.end(); b,_=argument(source,a); value=source[a:b].strip()
        if not value or value.startswith(('L(', 'action:', 'role:', 'value:', '{', 'verbatim:', 'localizedMaskName(')): continue
        # The UI shows these user values verbatim, even if a filename matches a label.
        if value in ('model.sourceName', 'item.name', 'preset.name', 'snapshot.name', 'copy.name'): continue
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*:',value): continue
        # Nested calls may also have edits; insertion spans compose safely.
        left=a+len(source[a:b])-len(source[a:b].lstrip());right=b-len(source[a:b])+len(source[a:b].rstrip())
        spans.extend([(left,'L('),(right,')')])
    for match in re.finditer(r'\.addButton\(withTitle:\s*', source):
        a=match.end(); b,_=argument(source,a)
        if not source[a:b].lstrip().startswith('L('): spans.extend([(a,'L('),(b,')')])
    for match in assignments.finditer(source):
        a=match.end()
        if source[a:a+2]=='L(':continue
        if source[a:a+1]=='"': b=skip_string(source,a);spans.extend([(a,'L('),(b,')')])
    if not spans:continue
    out=source
    for pos,insert in sorted(spans,reverse=True):out=out[:pos]+insert+out[pos:]
    changes+=len(spans)//2
    if '--check' not in sys.argv: path.write_text(out)
    print(f'{path.name}: {len(spans)//2} display boundaries')
print(f'{changes} pending adaptations' if '--check' in sys.argv else f'Adapted {changes} display boundaries')
if '--check' in sys.argv and changes:sys.exit(1)
