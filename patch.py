#!/usr/bin/env python3
"""Build a self-contained patched COPY. Never install, launch, or kill WeType."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
import macho
import version_profile

ROOT = Path(__file__).resolve().parent
PATCH_VERSION = '1.3.1'
TARGET_ARCHES = {'arm64'}
ENGLISH_ID = 'com.tencent.inputmethod.wetype.english'
ENGLISH_NAME = '微信输入法'
REVIEWED_PATCH_SITES = {
    ('global_mode', '_$s6WeType9InputModeV18isDefaultASCIIMode8bundleIDSbSS_tFZTf4nd_n', 0x100360728),
    ('disable_mode_reset', '_$s6WeType9InputModeV05resetcD0yyFZTf4d_n', 0x100360778),
    ('native_activation', '_$s6WeType15InputControllerC14activateServeryyypSgF', 0x1001187ac),
}


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
    activation = work / 'activation.o'
    run('xcrun', 'clang', '-arch', 'arm64', '-c', ROOT / 'src/activation-arm64.s', '-o', activation)
    words = run('xcrun', 'otool', '-s', '__TEXT', '__text', activation).decode().splitlines()[2:]
    code = b''.join(struct.pack('<I', int(word, 16)) for line in words for word in line.split()[1:])
    reviewed = next(item for item in profile['code_patches']['arm64'] if item['name'] == 'native_activation')
    if code != bytes.fromhex(reviewed['replacement']):
        raise ValueError('Activation assembly differs from reviewed code patch')
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


def code_patches(profile, arch):
    patches = profile.get('code_patches', {}).get(arch, [])
    if not isinstance(patches, list):
        raise ValueError(f'Invalid code patches for {arch}')
    if arch == 'arm64' and (len(patches) != 3 or
            {item.get('name') for item in patches if isinstance(item, dict)} !=
            {'global_mode', 'disable_mode_reset', 'native_activation'}):
        raise ValueError('This bridge requires the three reviewed native-mode patches')
    result = []
    for item in patches:
        if (not isinstance(item, dict) or set(item) != {'name', 'symbol', 'address', 'original',
                'replacement', 'patched_text_sha256'} or
            not isinstance(item['address'], int) or item['address'] < 0 or
            not isinstance(item['original'], str) or not isinstance(item['replacement'], str)):
            raise ValueError(f'Invalid reviewed code patch for {arch}')
        try:
            original = bytes.fromhex(item['original'])
            replacement = bytes.fromhex(item['replacement'])
        except ValueError as error:
            raise ValueError(f'Invalid code-patch bytes for {arch}') from error
        if not original or len(original) != len(replacement) or len(original) % 4:
            raise ValueError(f'Invalid code-patch width for {arch}')
        if arch != 'arm64' or (item['name'], item['symbol'], item['address']) not in REVIEWED_PATCH_SITES:
            raise ValueError(f'Unsupported reviewed code patch for {arch}')
        digest = item['patched_text_sha256']
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError(f'Invalid patched text fingerprint for {arch}')
        result.append((item, original, replacement))
    return result


def apply_code_patches(data, profile, arch):
    """Apply only byte-exact, reviewed instruction replacements inside __text."""
    parts = macho.slices(data)
    if len(parts) != 1 or parts[0]['arch'] != arch:
        raise ValueError(f'Expected one {arch} image for code patching')
    text = next(s for s in parts[0]['sections'] if s['segment'] == '__TEXT' and s['section'] == '__text')
    out = bytearray(data)
    ranges = []
    expected_digest = None
    for item, original, replacement in code_patches(profile, arch):
        address = item['address']
        if not text['address'] <= address or address + len(original) > text['address'] + text['size']:
            raise ValueError(f'Code patch outside __text: {item["name"]}')
        offset = text['offset'] + address - text['address']
        current = bytes(out[offset:offset + len(original)])
        if current != original:
            raise ValueError(f'Original instruction mismatch: {item["name"]}')
        if any(start < offset + len(original) and offset < end for start, end in ranges):
            raise ValueError(f'Overlapping code patch: {item["name"]}')
        ranges.append((offset, offset + len(original)))
        out[offset:offset + len(original)] = replacement
        if expected_digest is not None and expected_digest != item['patched_text_sha256']:
            raise ValueError(f'Conflicting patched text fingerprints for {arch}')
        expected_digest = item['patched_text_sha256']
    if expected_digest:
        patched = macho.slices(out)[0]
        patched_text = next(s for s in patched['sections'] if s['segment'] == '__TEXT' and s['section'] == '__text')
        if patched_text['sha256'] != expected_digest:
            raise ValueError(f'Patched text fingerprint mismatch for {arch}')
    return bytes(out)


def expected_text_sha256(profile, arch):
    patches = code_patches(profile, arch)
    return patches[0][0]['patched_text_sha256'] if patches else profile['architectures'][arch]['text_sha256']


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
        if text['sha256'] != expected_text_sha256(expected, part['arch']):
            raise ValueError('Executable instructions differ from the reviewed original plus code patches')
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
    for arch in target_arches:
        code_patches(expected, arch)
    return {'verified': True, 'tool_version': PATCH_VERSION, 'architectures': sorted(target_arches),
            'english_entry': english, 'native_mode_decision': True,
            'note': 'Ad-hoc integrity/static checks only; live input tests are separate.'}


def build(source, output, profile_path, english):
    source, output = source.resolve(), output.resolve()
    if output.suffix != '.app' or source == output or source in output.parents or output in source.parents:
        raise ValueError('Input and output must be separate, non-nested .app paths')
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
    patched = apply_code_patches(patched, reviewed, 'arm64')
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
        # Replace the entire old bundle only after the new build passes verification.
        if output.exists():
            shutil.rmtree(output)
        os.replace(stage, output)
    return {'output': str(output), **result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    inspect = commands.add_parser('inspect', help='Print UNREVIEWED candidate profile; no app changes')
    inspect.add_argument('app', type=Path)
    create = commands.add_parser('build', help='Build a self-contained patched copy, replacing existing output; never install it')
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
