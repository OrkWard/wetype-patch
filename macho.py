"""Conservative, dependency-free Mach-O header-padding patcher (no file shifting)."""
from __future__ import annotations
import hashlib
import struct

LOAD_PATH = '@executable_path/../Frameworks/libwetype-bridge.dylib'
LC_LOAD_DYLIB = 0xC
DYLIB_COMMANDS = {0xC, 0xD, 0x80000018, 0x8000001F, 0x20, 0x80000023}
LINKEDIT_COMMANDS = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034}
NO_PAYLOAD_COMMANDS = {4, 5, 0xE, 0xF, 0x12, 0x13, 0x14, 0x15, 0x1A, 0x1B,
                       0x8000001C, 0x24, 0x2A, 0x2D, 0x32, 0x80000028}
ARCHES = {0x1000007: 'x86_64', 0x100000C: 'arm64'}


class InvalidMachO(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidMachO(message)


def dylib_command(path=LOAD_PATH):
    raw = path.encode('utf-8')
    require(raw and b'\0' not in raw, 'Invalid dylib path')
    size = (24 + len(raw) + 1 + 7) & ~7
    return struct.pack('<6I', LC_LOAD_DYLIB, size, 24, 0, 0x10000, 0x10000) + raw + bytes(size - 24 - len(raw))


def slices(data):
    require(len(data) >= 32, 'Truncated Mach-O')
    magic = data[:4]
    if magic == b'\xcf\xfa\xed\xfe':
        entries = [(0, len(data), None, None)]
    elif magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', data, 4)[0]
        size = 32 if magic[-1] == 0xBF else 20
        require(0 < count <= 16 and 8 + count * size <= len(data), 'Invalid fat header')
        entries = []
        end = 8 + count * size
        for i in range(count):
            fields = struct.unpack_from('>IIQQII' if size == 32 else '>IIIII', data, 8 + i * size)
            cpu, subtype, off, length, align = fields[:5]
            require(align <= 30 and off % (1 << align) == 0, 'Invalid slice alignment')
            require(off >= end and length >= 32 and off + length <= len(data), 'Invalid fat slice bounds')
            entries.append((off, length, cpu, subtype))
        ranges = sorted((off, off + length) for off, length, _, _ in entries)
        require(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])), 'Overlapping fat slices')
    else:
        raise InvalidMachO('Only little-endian 64-bit Mach-O and big-endian fat headers are supported')
    result = []
    seen = set()
    for off, length, fat_cpu, fat_subtype in entries:
        d = memoryview(data)[off:off + length]
        magic, cpu, subtype, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from('<8I', d)
        require(magic == 0xFEEDFACF and cpu in ARCHES, 'Unsupported architecture')
        require((cpu == 0x1000007 and subtype & 0xFFFFFF == 3) or
                (cpu == 0x100000C and subtype & 0xFFFFFF == 0), 'Unsupported CPU subtype')
        require(fat_cpu is None or (cpu, subtype) == (fat_cpu, fat_subtype), 'Fat/thin architecture mismatch')
        require(cpu not in seen, 'Duplicate architecture')
        seen.add(cpu)
        require(filetype in (2, 6), 'Expected executable or dylib')
        end = 32 + sizeofcmds
        require(0 < ncmds <= 4096 and end <= length, 'Invalid load-command bounds')
        first = length
        sections = []
        libraries = []

        def payload(start, size):
            nonlocal first
            if size:
                require(start >= end and start + size <= length, 'Invalid/overlapping file payload')
                first = min(first, start)

        q = 32
        for _ in range(ncmds):
            require(q + 8 <= end, 'Truncated load command')
            cmd, size = struct.unpack_from('<II', d, q)
            require(size >= 8 and size % 8 == 0 and q + size <= end, 'Invalid load-command size')
            if cmd == 0x19:  # LC_SEGMENT_64
                require(size >= 72, 'Truncated segment')
                fileoff, filesize = struct.unpack_from('<QQ', d, q + 40)
                nsects = struct.unpack_from('<I', d, q + 64)[0]
                require(size == 72 + 80 * nsects and fileoff + filesize <= length, 'Invalid segment')
                if fileoff:
                    payload(fileoff, filesize)
                for j in range(nsects):
                    s = q + 72 + 80 * j
                    name = bytes(d[s:s + 16]).rstrip(b'\0').decode('ascii')
                    segment = bytes(d[s + 16:s + 32]).rstrip(b'\0').decode('ascii')
                    address, section_size, section_off, _, reloff, nreloc, flags = struct.unpack_from('<QQIIIII', d, s + 32)
                    payload(reloff, nreloc * 8)
                    if flags & 0xFF not in (1, 0xC, 0x12) and section_size:
                        payload(section_off, section_size)
                        require(fileoff <= section_off and section_off + section_size <= fileoff + filesize,
                                'Section outside segment')
                        sections.append({'segment': segment, 'section': name, 'offset': section_off,
                                         'address': address, 'size': section_size,
                                         'sha256': hashlib.sha256(d[section_off:section_off + section_size]).hexdigest()})
            elif cmd in DYLIB_COMMANDS:
                require(size >= 24, 'Truncated dylib command')
                nameoff = struct.unpack_from('<I', d, q + 8)[0]
                require(24 <= nameoff < size, 'Invalid dylib name offset')
                raw = bytes(d[q + nameoff:q + size])
                require(b'\0' in raw, 'Unterminated dylib name')
                libraries.append({'command': cmd, 'path': raw.split(b'\0', 1)[0].decode('utf-8')})
            elif cmd in LINKEDIT_COMMANDS or cmd == 0x16:
                require(size == 16, 'Invalid linkedit command')
                start, count = struct.unpack_from('<II', d, q + 8)
                payload(start, count * 4 if cmd == 0x16 else count)
            elif cmd == 2:  # LC_SYMTAB
                require(size == 24, 'Invalid symbol table command')
                symoff, nsyms, stroff, strsize = struct.unpack_from('<4I', d, q + 8)
                payload(symoff, nsyms * 16)
                payload(stroff, strsize)
            elif cmd == 0xB:  # LC_DYSYMTAB
                require(size == 80, 'Invalid dynamic symbol table command')
                for field, width in zip(range(32, 80, 8), (8, 56, 4, 4, 8, 8)):
                    start, count = struct.unpack_from('<II', d, q + field)
                    payload(start, count * width)
            elif cmd in (0x22, 0x80000022):
                require(size == 48, 'Invalid dyld info command')
                for field in range(8, 48, 8):
                    payload(*struct.unpack_from('<II', d, q + field))
            elif cmd == 0x2C:
                require(size == 24, 'Invalid encryption command')
                start, count, cryptid = struct.unpack_from('<III', d, q + 8)
                require(cryptid == 0, 'Encrypted binaries are unsupported')
                payload(start, count)
            elif cmd == 0x31:
                require(size == 40, 'Invalid note command')
                payload(*struct.unpack_from('<QQ', d, q + 24))
            else:
                require(cmd in NO_PAYLOAD_COMMANDS, f'Unreviewed load command {cmd:#x}')
            q += size
        require(q == end and sections, 'Invalid command total or no file-backed sections')
        require(any(s['section'] == '__text' for s in sections), 'Missing __text')
        result.append({'arch': ARCHES[cpu], 'offset': off, 'size': length, 'filetype': filetype,
                       'ncmds': ncmds, 'sizeofcmds': sizeofcmds, 'padding': first - end,
                       'padding_is_zero': not any(d[end:first]), 'sections': sections, 'libraries': libraries})
    return result


def patch(data, path=LOAD_PATH):
    """Return patched bytes. Preflight ALL slices; never relocate existing data."""
    command = dylib_command(path)
    plans = []
    for part in slices(data):
        require(part['filetype'] == 2, 'Only patch executables')
        matches = [lib for lib in part['libraries'] if lib['path'] == path]
        if matches:
            require(len(matches) == 1 and matches[0]['command'] == LC_LOAD_DYLIB, 'Conflicting existing dependency')
            continue
        require(part['padding'] >= len(command), f"Insufficient header padding in {part['arch']}")
        require(part['padding_is_zero'], f"Nonzero header padding in {part['arch']}")
        plans.append(part)
    out = bytearray(data)
    for part in plans:
        off = part['offset']
        start = off + 32 + part['sizeofcmds']
        out[start:start + len(command)] = command
        struct.pack_into('<II', out, off + 16, part['ncmds'] + 1, part['sizeofcmds'] + len(command))
    before, after = slices(data), slices(out)
    require([p['sections'] for p in before] == [p['sections'] for p in after], 'Section content/layout changed')
    return bytes(out)
