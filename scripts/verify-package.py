#!/usr/bin/env python3
"""Validate the shipped bundle without installing/launching its live UI.
--live makes one read-only live diagnosis. --render captures synthetic native content.
"""
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'dist/T3 Usage.app'
exe = app / 'Contents/MacOS/T3Usage'
evidence = root / 'Evidence'
evidence.mkdir(exist_ok=True)

def run(args, timeout=10):
    return subprocess.run([str(exe), *args], cwd='/tmp', text=True, capture_output=True, timeout=timeout)

def diagnosis(args):
    result = run([*args, '--diagnose'], timeout=50)
    if result.returncode != 0:
        raise RuntimeError('Packaged diagnosis failed; no raw process output exported')
    if result.stderr:
        raise RuntimeError('Packaged diagnosis emitted stderr; inspect locally before delivery')
    data = json.loads(result.stdout)
    allowed = {'schema','mode','read','mechanism','forcedProviderProbe','accounts','hubSources',
               'selectedAccountPresent','readSessionRevoked','selectedAccountHash','driver','windowCount',
               'selectedWindowPresent','selectedWindowKind','remainingPercent','statusBar','state','checkedAt','resetAt'}
    assert set(data) <= allowed
    assert '@' not in result.stdout
    assert data['read'] == 'success' and data['forcedProviderProbe'] is False
    return data

subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)], check=True)
arch = subprocess.check_output(['/usr/bin/lipo','-archs',str(exe)],text=True).strip()
assert arch == 'arm64'
assert subprocess.check_output(['/usr/bin/plutil','-extract','LSUIElement','raw',str(app/'Contents/Info.plist')],text=True).strip() == 'true'
assert run(['--help']).returncode == 0
for args in [['--fixture'],['--fixture','unknown'],['--render-fixture'],['--render-fixture','a.png'],['--diagnos'],['--dark']]:
    assert run(args, timeout=3).returncode == 2

fixtures = {}
for scenario, expected in [('current','63%'),('stale','~63%'),('failed','—'),('unsupported','—'),('missing','—'),('reset','—')]:
    data = diagnosis(['--fixture',scenario])
    assert data['statusBar'] == expected
    assert data['mode'] == 'fixture'
    fixtures[scenario] = data
    if '--render' in sys.argv:
        assert run(['--fixture',scenario,'--render-fixture',str(evidence/f'fixture-{scenario}.png')]).returncode == 0
if '--render' in sys.argv:
    assert run(['--fixture','current','--dark','--render-fixture',str(evidence/'fixture-dark.png')]).returncode == 0
(evidence/'fixture-diagnoses.json').write_text(json.dumps(fixtures,indent=2)+'\n')

live = None
if '--live' in sys.argv:
    live = diagnosis([])
    assert live['mode'] == 'live'
    assert live['readSessionRevoked'] is True
    (evidence/'live-packaged-diagnose.json').write_text(json.dumps(live,indent=2)+'\n')

report = {'verifiedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'bundle':str(app),'arch':arch,'signature':'ad-hoc; codesign strict verified','LSUIElement':True,
          'fixtureScenarios':list(fixtures),'invalidArgumentChecks':6,'liveReadPerformed':live is not None,
          'syntheticRenderPerformed':'--render' in sys.argv,
          'liveGUIStarted':False,'installed':False,
          'binarySHA256':hashlib.sha256(exe.read_bytes()).hexdigest(),
          'zipSHA256':hashlib.sha256((root/'dist/T3-Usage-arm64.zip').read_bytes()).hexdigest()}
(evidence/'package-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
