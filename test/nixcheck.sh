#!/usr/bin/env bash
# Nix grammar: bindings as module symbols, lambda reclassification, module-scope rule, call edges,
# parameter counts, and the honest floors (dynamic dispatch, import, nested data). The fixture shapes
# are the two real-world module spellings: an anonymous root lambda returning the module attrset
# (mod.nix) and a root attrset file (plain.nix).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${RIPWIRE_BIN:-$ROOT/build/ripwire}"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"   # absolute: the root-equivalence arm cds
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/cache"
export XDG_CACHE_HOME="$TMP/cache"
cp -R "$ROOT/test/nixfix" "$TMP/fix"
"$BIN" "$TMP/fix" --no-cache > "$TMP/map.xml"
python3 - "$TMP/map.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
syms = {s.get('n'): s for s in root.iter('s')}
# Every binding the two fixtures carry, with the kind the reclassification gives it, and NOTHING
# else — the absences below are the disclosed floors, each one a rule that must not regress.
expected = {
    'enable': 'var',      # options.host.caddy.enable — the LAST attr, not the whole path
    'mkTitle': 'fn',      # universal: ... — first application of the curried chain
    'curried': 'fn',      # a: b: ... — still one parameter at the first application
    'formalFn': 'fn',     # { name, arch ? "...", ... }: — 2 formals, ellipses excluded
    'midLambda': 'fn',    # lambda-valued at top level: a callable at any depth
    'usesMkTitle': 'var', # data binding whose value calls mkTitle — the honest caller
    'callPkg': 'var',     # callPackage ./missing.nix — a value, and its head is NOT an edge
    'module': 'var',      # import ./plain.nix — a value; import is NOT a call symbol
    'ghost': 'var',       # import ./nope.nix — a value; the missing target is a deps floor
    'pkgs': 'var',        # import <nixpkgs> { } — a value; the NIX_PATH floor
    'answer': 'var',      # plain.nix: the file root is data, the file is the module unit
    'invokes': 'var',     # cross-file call by bare name
    'localFn': 'fn',      # a nested function inside the root data file is still a callable
    'readPort': 'fn',     # options.services.caddy.readPort — lambda-valued multi-seg path
    'branchy': 'fn',      # if c then 1 else 0 — the one decision spelling Nix has
}
assert set(syms) == set(expected), (set(syms), set(expected))
for name, kind in expected.items():
    assert syms[name].get('t') == kind, (name, syms[name].attrib)
# ---- the decoys: a name that must NOT become a symbol because the anchor or the scope rule ate it
for absent in ('options', 'host', 'caddy', 'services', 'inner', 'callPackage', 'import'):
    assert absent not in syms, (absent, 'became an indexed symbol')
# ---- edges: currying emits ONE reference (to the first application), the data binding is the caller
def calls(name): return {c.get('n') for c in syms[name].iter('c')}
assert calls('usesMkTitle') == {'mkTitle'}, calls('usesMkTitle')
# the declined local `inner` is not a symbol, but the call inside it still attributes to the
# enclosing FUNCTION — the nearest captured ancestor, exactly like a Python function body
assert calls('midLambda') == {'mkTitle'}, calls('midLambda')
assert 'callPackage' not in calls('callPkg'), 'dynamic dispatch minted an edge'
assert 'import' not in calls('module'), 'import became a call edge'
print('  PASS Nix bindings, kinds, decoys, and the dynamic-dispatch/import floors')
PY
"$BIN" "$TMP/fix" --no-cache --callers=mkTitle > "$TMP/callers.xml"
python3 - "$TMP/callers.xml" <<'PYCALL'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
assert r.get('defs') == '1', r.attrib
assert r.get('count') == '3', 'cross-file caller lost or doubled'
rows = {(c.get('n'), c.get('t')) for c in r.iter('s')}
assert {('usesMkTitle', 'var'), ('invokes', 'var'), ('midLambda', 'fn')} <= rows, rows
assert r.get('graph_ambiguous') == '0', r.attrib
print('  PASS cross-file caller edge attributes to the data binding')
PYCALL

# ---- cold/warm determinism: three runs through the cache and one cold, byte-identical
for n in a b c; do "$BIN" "$TMP/fix" > "$TMP/$n.xml"; done
cmp "$TMP/map.xml" "$TMP/a.xml"
cmp "$TMP/a.xml" "$TMP/b.xml"
cmp "$TMP/b.xml" "$TMP/c.xml"
echo '  PASS cold/warm determinism and XML'

# ---- a relative and an absolute crawl root resolve identically
# (the root= label itself echoes the crawl root AS GIVEN, by design — normalize it, compare the rest)
cd "$TMP" && "$BIN" fix --no-cache > "$TMP/rel.xml"
cd "$ROOT" && "$BIN" "$TMP/fix" --no-cache > "$TMP/abs.xml"
python3 - "$TMP/rel.xml" "$TMP/abs.xml" <<'PYROOT'
import re, sys
# root= echoes the crawl root AS GIVEN and est_tokens prices its bytes — both by design; normalize
# both and assert every symbol, edge and count the two invocations share is identical
norm = lambda p: re.sub( r'est_tokens="?\d+"?', 'E', re.sub( r'root="[^"]*"', 'R', open( p ).read() ) )
assert norm( sys.argv[1] ) == norm( sys.argv[2] ), 'relative and absolute roots disagree beyond the label'
PYROOT
echo '  PASS relative and absolute crawl roots agree'

# ---- call-site mutation removes the edge
python3 - "$TMP/fix/mod.nix" <<'PYMUT'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
assert 'usesMkTitle = mkTitle' in s
p.write_text(s.replace('usesMkTitle = mkTitle "t" "u"', 'usesMkTitle = mkTitleX "t" "u"'))
PYMUT
"$BIN" "$TMP/fix" --no-cache > "$TMP/mut.xml"
python3 - "$TMP/mut.xml" <<'PYMUTX'
import sys, xml.etree.ElementTree as ET
syms = {s.get('n'): s for s in ET.parse(sys.argv[1]).iter('s')}
assert 'mkTitle' in syms
assert 'mkTitleX' not in {c.get('n') for c in syms['usesMkTitle'].iter('c')}
print('  PASS call-site mutation removes the edge')
PYMUTX

# ---- parameter counts and branch metrics
"$BIN" "$TMP/fix" --metrics --no-cache > "$TMP/metrics.xml"
python3 - "$TMP/metrics.xml" <<'PYMET'
import sys, xml.etree.ElementTree as ET
syms = {s.get('n'): s for s in ET.parse(sys.argv[1]).iter('s')}
assert syms['mkTitle'].get('params') == '1', syms['mkTitle'].attrib
assert syms['curried'].get('params') == '1', syms['curried'].attrib
assert syms['formalFn'].get('params') == '2', syms['formalFn'].attrib
assert syms['branchy'].get('cx') == '2', syms['branchy'].attrib
print('  PASS Nix parameter counts and if-expression metrics')
PYMET

# ---- malformed Nix does not crash, output stays well-formed XML
# (well-formedness is asserted with the stdlib parser: xmllint is not on every leg — selfcontainedcheck
#  degrades the same way, and the parse IS the well-formedness contract here)
mkdir "$TMP/broken"
printf 'let\n  x = { a = 1;\n' > "$TMP/broken/broken.nix"
"$BIN" "$TMP/broken" --no-cache > "$TMP/broken.xml"
python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$TMP/broken.xml"
echo '  PASS malformed file does not crash and stays well-formed XML'

# ---- file dependencies: resolved, missing, and NIX_PATH floors
"$BIN" "$TMP/fix" --no-cache --deps > "$TMP/deps.xml"
python3 - "$TMP/deps.xml" <<'PYDEPS'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
assert 'nix' in r.find('health').get('dep_langs'), 'nix missing from the dep_langs denominator'
files = {f.get('p'): f for f in r.iter('f')}
mod = files['mod.nix']
assert mod.get('includes') == '3', mod.attrib                # plain.nix + nope.nix + <nixpkgs>
incs = {i.get('t'): i for i in mod.iter('inc')}
assert './plain.nix' in incs and './nope.nix' in incs and '<nixpkgs>' in incs, set(incs)
# the NIX_PATH spath is captured (isAngle internally) but resolves to nothing — the same visible
# disclosure as an unresolvable `#include <vector>`: an inc row with no file row behind it
plain = files['plain.nix']
assert plain.get('afferent') == '1', plain.attrib            # the ONE resolved edge lands
assert files.get('nope.nix') is None, 'a missing target materialized a file row'
print('  PASS file dependencies: resolved edge, missing target, and the NIX_PATH angle tier')
PYDEPS

# ---- doctor loads the full grammar roster
PATH="$(cd "$(dirname "$BIN")" && pwd):$PATH" "$BIN" "$TMP/fix" --doctor > "$TMP/doctor.xml"
python3 - "$TMP/doctor.xml" <<'PYDOC'
import sys, xml.etree.ElementTree as ET
rows = [c for c in ET.parse(sys.argv[1]).iter('c') if c.get('n') == 'grammars']
assert len(rows) == 1
assert rows[0].get('loaded') == rows[0].get('expected') == '26', rows[0].attrib
print('  PASS doctor loads all 26 grammars and queries')
PYDOC
