"""Version review metadata. Finding symbols is NOT a semantic compatibility review."""
import hashlib
import plistlib
import struct
from pathlib import Path
import macho

SYMBOLS = {
    'getter': '_$s6WeType15InputControllerC16currentASCIIModeSbvg',
    'controller_slot': '_$s6WeType1GV22currentInputControllerAA0dE0CSgvpZ',
    'controller_init_token': '_$s6WeType1GV22currentInputController_Wz',
    'toggle_action': '_$s6WeType11AppDelegateC15changeInputModeyyFTo',
}


def inspect(app):
    app = Path(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = info['CFBundleExecutable']
    if Path(executable).name != executable:
        raise ValueError('Unsafe CFBundleExecutable')
    data = (app / 'Contents/MacOS' / executable).read_bytes()
    result = {'schema': 1, 'reviewed': False,
              'bundle_id': info['CFBundleIdentifier'],
              'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
              'executable': executable, 'executable_sha256': hashlib.sha256(data).hexdigest(),
              'symbols': SYMBOLS, 'architectures': {}}
    for part in macho.slices(data):
        d = memoryview(data)[part['offset']:part['offset'] + part['size']]
        q = 32
        symtab = None
        for _ in range(part['ncmds']):
            cmd, size = struct.unpack_from('<II', d, q)
            if cmd == 2:
                symtab = struct.unpack_from('<4I', d, q + 8)
            q += size
        if not symtab:
            raise ValueError('Symbol table missing: explicit re-analysis required')
        symoff, count, stroff, strsize = symtab
        strings = bytes(d[stroff:stroff + strsize])
        addresses = {}
        expected = {name.encode(): key for key, name in SYMBOLS.items()}
        for i in range(count):
            nameoff, kind, section, _, address = struct.unpack_from('<IBBHQ', d, symoff + 16 * i)
            if kind & 0xE0 or kind & 0xE != 0xE or not section:
                continue
            end = strings.find(b'\0', nameoff)
            if end == -1:
                raise ValueError('Malformed symbol name')
            key = expected.get(strings[nameoff:end])
            if key:
                if key in addresses:
                    raise ValueError(f'Duplicate private symbol: {key}')
                addresses[key] = address
        if set(addresses) != set(SYMBOLS):
            raise ValueError(f"Missing private symbols in {part['arch']}; do not guess offsets")
        text = next(s for s in part['sections'] if s['segment'] == '__TEXT' and s['section'] == '__text')
        for key in ('getter', 'toggle_action'):
            if not text['address'] <= addresses[key] < text['address'] + text['size']:
                raise ValueError(f'{key} not inside __text')
        result['architectures'][part['arch']] = {
            'header_padding': part['padding'], 'padding_is_zero': part['padding_is_zero'],
            'text_sha256': text['sha256'], 'addresses': addresses,
        }
    return result


def check_review(actual, reviewed):
    # 'reviewed' is a maintainer's explicit assertion, not an independent signature.
    required = {'schema', 'bundle_id', 'version', 'build', 'executable', 'executable_sha256', 'symbols', 'architectures'}
    for value in (actual, reviewed):
        if not isinstance(value, dict) or not required.issubset(value):
            raise ValueError('Incomplete version profile')
        if value['schema'] != 1 or value['symbols'] != SYMBOLS:
            raise ValueError('Unsupported profile schema/symbols')
        digest = value['executable_sha256']
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('Invalid executable fingerprint')
        arches = value['architectures']
        if not isinstance(arches, dict) or not arches or not set(arches).issubset({'arm64', 'x86_64'}):
            raise ValueError('Invalid profile architectures')
    if reviewed.get('reviewed') is not True:
        raise ValueError('Profile is not explicitly reviewed')
    for key in required:
        if actual[key] != reviewed[key]:
            raise ValueError(f'Unreviewed input: {key} differs from profile')
    if actual['bundle_id'] != 'com.tencent.inputmethod.wetype':
        raise ValueError('Wrong bundle ID')


def header(reviewed):
    lines = ['// Generated, never hand-edit addresses here.', '#include <stdint.h>',
             f'#define WT_HOST_VERSION "{reviewed["version"]}"',
             f'#define WT_HOST_BUILD "{reviewed["build"]}"']
    for i, (arch, part) in enumerate(sorted(reviewed['architectures'].items())):
        lines.append(('#if' if i == 0 else '#elif') + f' defined(__{arch}__)')
        for key, macro in [('getter', 'WT_GETTER_ADDRESS'), ('controller_slot', 'WT_CONTROLLER_SLOT'),
                           ('controller_init_token', 'WT_CONTROLLER_INIT_TOKEN')]:
            lines.append(f'#define {macro} UINT64_C({part["addresses"][key]:#x})')
        patches = reviewed.get('code_patches', {}).get(arch, [])
        text_sha256 = patches[0]['patched_text_sha256'] if patches else part['text_sha256']
        if any(patch.get('patched_text_sha256') != text_sha256 for patch in patches):
            raise ValueError(f'Conflicting patched text fingerprints for {arch}')
        digest = ', '.join(f'0x{x:02x}' for x in bytes.fromhex(text_sha256))
        lines.append(f'static const unsigned char WT_TEXT_SHA256[32] = {{{digest}}};')
    lines.extend(['#else', '#error Unreviewed architecture', '#endif', ''])
    return '\n'.join(lines)
