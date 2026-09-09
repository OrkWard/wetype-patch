#!/usr/bin/env python3
"""Build a self-contained patched COPY. Never install, launch, or kill WeType."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import macho
import version_profile

ROOT = Path(__file__).resolve().parent
PATCH_VERSION = '1.0.1'
TARGET_ARCHES = {'arm64'}
ENGLISH_ID = 'com.tencent.inputmethod.wetype.english'
ENGLISH_NAME = '微信输入法'


def run(*args):
    completed = subprocess.run([str(x) for x in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode:
        raise RuntimeError(f"Command failed: {' '.join(map(str, args))}\n{completed.stderr.decode(errors='replace')}")
    return completed.stdout


def entitlements(app):
    return plistlib.loads(run('codesign', '-d', '--entitlements', '-', '--xml', app))


def add_name(path):
    raw = path.read_bytes()
    if raw.startswith(b'bplist') or raw.lstrip().startswith(b'<?xml'):
        values = plistlib.loads(raw)
        if ENGLISH_ID in values and values[ENGLISH_ID] != ENGLISH_NAME:
            raise ValueError(f'Conflicting English name: {path}')
        values[ENGLISH_ID] = ENGLISH_NAME
        path.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML))
    else:
        if raw.startswith(b'\xff\xfe'):
            encoding, bom = 'utf-16-le', b'\xff\xfe'
        elif raw.startswith(b'\xfe\xff'):
            encoding, bom = 'utf-16-be', b'\xfe\xff'
        elif raw.startswith(b'\xef\xbb\xbf'):
            encoding, bom = 'utf-8', b'\xef\xbb\xbf'
        else:
            encoding, bom = 'utf-8', b''
        text = raw[len(bom):].decode(encoding)
        addition = f'"{ENGLISH_ID}" = "{ENGLISH_NAME}";\n'
        if ENGLISH_ID in text:
            if addition.strip() not in text:
                raise ValueError(f'Conflicting English name: {path}')
            return
        # Preserve original bytes, BOM, and newline contents.
        path.write_bytes(raw + (('' if text.endswith('\n') else '\n') + addition).encode(encoding))


def add_english(app):
    path = app / 'Contents/Info.plist'
    info = plistlib.loads(path.read_bytes())
    component = info['ComponentInputModeDict']
    modes = component['tsInputModeListKey']
    original = modes['com.tencent.inputmethod.wetype.pinyin']
    entry = {'TISInputSourceID': ENGLISH_ID, 'TISIntendedLanguage': 'en',
             'tsInputModeDefaultStateKey': True, 'tsInputModeIsVisibleKey': True}
    for key in ('tsInputModeMenuIconFileKey', 'tsInputModeAlternateMenuIconFileKey', 'tsInputModePaletteIconFileKey'):
        if key in original:
            entry[key] = original[key]
    if ENGLISH_ID in modes and modes[ENGLISH_ID] != entry:
        raise ValueError('Conflicting English mode')
    modes[ENGLISH_ID] = entry
    order = component.setdefault('tsVisibleInputModeOrderedArrayKey', list(modes))
    if ENGLISH_ID not in order:
        order.append(ENGLISH_ID)
    path.write_bytes(plistlib.dumps(info, sort_keys=False))
    resources = app / 'Contents/Resources'
    paths = [resources / 'InfoPlist.strings', *sorted(resources.glob('*.lproj/InfoPlist.strings'))]
    if not paths[0].exists():
        paths[0].write_text('', encoding='utf-8')
    for name in paths:
        add_name(name)
        run('plutil', '-lint', name)
    run('plutil', '-lint', path)


def compile_tools(work, app, profile):
    (work / 'state-profile.h').write_text(version_profile.header(profile), encoding='utf-8')
    targets = {
        'libwetype-bridge.dylib': (['bridge.m', 'state.m'], ['-dynamiclib', '-Wl,-install_name,' + macho.LOAD_PATH],
                                  app / 'Contents/Frameworks/libwetype-bridge.dylib'),
        'wetype-cli': (['wetype-cli.m'], [], app / 'Contents/MacOS/wetype-cli'),
    }
    for name, (sources, extra, destination) in targets.items():
        thin = []
        for arch in sorted(TARGET_ARCHES):
            target = work / f'{arch}-{name}'
            minimum = '11.0' if arch == 'arm64' else '10.15'
            run('xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O2', '-Wall', '-Wextra', '-Werror',
                '-arch', arch, '-mmacosx-version-min=' + minimum, '-I', work,
                *extra, *(ROOT / 'src' / s for s in sources), '-framework', 'Cocoa', '-framework', 'Carbon', '-o', target)
            thin.append(target)
        destination.parent.mkdir(parents=True, exist_ok=True)
        run('xcrun', 'lipo', '-create', *thin, '-output', destination)
        destination.chmod(0o755)
        run('codesign', '--force', '--sign', '-', '--timestamp=none', destination)


def verify(app, expected=None):
    run('codesign', '--verify', '--deep', '--strict', app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if expected is None:
        candidates = []
        for path in sorted((ROOT / 'profiles').glob('*.json')):
            candidate = json.loads(path.read_text())
            if (candidate.get('reviewed') is True and
                candidate.get('bundle_id') == info['CFBundleIdentifier'] and
                candidate.get('version') == info['CFBundleShortVersionString'] and
                candidate.get('build') == info['CFBundleVersion']):
                candidates.append(candidate)
        if len(candidates) != 1:
            raise ValueError('Need exactly one matching reviewed external profile')
        expected = candidates[0]
    version_profile.check_review(expected, expected)
    for key, value in [('CFBundleIdentifier', expected['bundle_id']), ('CFBundleVersion', expected['build']),
                        ('CFBundleShortVersionString', expected['version'])]:
        if info[key] != value:
            raise ValueError('Host metadata differs from reviewed profile')
    main = app / 'Contents/MacOS' / expected['executable']
    parts = macho.slices(main.read_bytes())
    target_arches = TARGET_ARCHES
    if {p['arch'] for p in parts} != target_arches:
        raise ValueError('Architecture set changed')
    for part in parts:
        matches = [x for x in part['libraries'] if x['path'] == macho.LOAD_PATH]
        if matches != [{'command': macho.LC_LOAD_DYLIB, 'path': macho.LOAD_PATH}]:
            raise ValueError('Missing/duplicate/wrong bridge load command')
        text = next(s for s in part['sections'] if s['section'] == '__text' and s['segment'] == '__TEXT')
        if text['sha256'] != expected['architectures'][part['arch']]['text_sha256']:
            raise ValueError('Original executable instructions changed')
    for relative in ('Contents/Frameworks/libwetype-bridge.dylib', 'Contents/MacOS/wetype-cli'):
        file = app / relative
        images = macho.slices(file.read_bytes())
        if {p['arch'] for p in images} != target_arches:
            raise ValueError(f'Architecture mismatch: {relative}')
        for image in images:
            for library in image['libraries']:
                if library['command'] == 0xD:  # LC_ID_DYLIB, not a dependency
                    continue
                if not library['path'].startswith(('/System/Library/', '/usr/lib/')):
                    raise ValueError(f'External bridge/helper dependency: {library["path"]}')
    rights = entitlements(app)
    if rights.get('com.apple.security.get-task-allow') or rights.get('com.apple.security.cs.disable-library-validation') is not True:
        raise ValueError('Unexpected patched-host entitlements')
    for relative in ('Contents/Resources/WeTypePatch', 'Contents/MacOS/wetype-tis'):
        if (app / relative).exists():
            raise ValueError(f'Non-runtime patch material still bundled: {relative}')
    modes = info['ComponentInputModeDict']['tsInputModeListKey']
    english = ENGLISH_ID in modes
    if english and modes[ENGLISH_ID]['TISIntendedLanguage'] != 'en':
        raise ValueError('Incorrect English-entry language')
    return {'verified': True, 'tool_version': PATCH_VERSION, 'architectures': sorted(target_arches),
            'english_entry': english, 'note': 'Ad-hoc integrity/static checks only; live input tests are separate.'}


def build(source, output, profile_path, english):
    source, output = source.resolve(), output.resolve()
    if output.exists() or output.suffix != '.app' or source == output or source in output.parents:
        raise ValueError('Output must be a NEW .app outside the source bundle')
    if 'Input Methods' in output.parts:
        raise ValueError('Build outside Input Methods; deployment is a separate manual step')
    reviewed = json.loads(profile_path.read_text())
    actual = version_profile.inspect(source)
    version_profile.check_review(actual, reviewed)
    run('codesign', '--verify', '--deep', '--strict', source)
    rights = entitlements(source)
    rights.pop('com.apple.security.get-task-allow', None)
    rights['com.apple.security.cs.disable-library-validation'] = True
    original = (source / 'Contents/MacOS' / actual['executable']).read_bytes()
    arm = next(part for part in macho.slices(original) if part['arch'] == 'arm64')
    patched = macho.patch(original[arm['offset']:arm['offset'] + arm['size']])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.wetype-build-', dir=output.parent) as temp:
        work = Path(temp)
        stage = work / 'WeType.app'
        shutil.copytree(source, stage, symlinks=True)
        main = stage / 'Contents/MacOS' / actual['executable']
        if hashlib.sha256(main.read_bytes()).hexdigest() != actual['executable_sha256']:
            raise ValueError('Source executable changed while copying')
        run('codesign', '--verify', '--deep', '--strict', stage)
        main.write_bytes(patched)
        if english:
            add_english(stage)
        compile_tools(work, stage, reviewed)
        rights_file = work / 'entitlements.plist'
        rights_file.write_bytes(plistlib.dumps(rights))
        run('codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements', rights_file, '--timestamp=none', stage)
        result = verify(stage, reviewed)
        # No overwrite: never replace an existing output or a live installation.
        if output.exists():
            raise ValueError('Output appeared during build; refusing overwrite')
        os.rename(stage, output)
    return {'output': str(output), **result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    inspect = commands.add_parser('inspect', help='Print UNREVIEWED candidate profile; no app changes')
    inspect.add_argument('app', type=Path)
    create = commands.add_parser('build', help='Create a new self-contained patched copy, never install it')
    create.add_argument('--input', required=True, type=Path)
    create.add_argument('--output', required=True, type=Path)
    create.add_argument('--profile', required=True, type=Path)
    create.add_argument('--english-entry', action='store_true', help='Add English entry, preserving original Chinese mode')
    check = commands.add_parser('verify', help='Check signatures, load commands, code hashes and dependencies using external profiles')
    check.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'inspect':
            result = version_profile.inspect(args.app)
        elif args.command == 'verify':
            result = verify(args.app)
        else:
            result = build(args.input, args.output, args.profile, args.english_entry)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except (ValueError, KeyError, OSError, RuntimeError) as error:
        print(f'REFUSED: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
