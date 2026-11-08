"""Bounded, byte-preserving Mach-O inspection and load-command injection.

Only thin, little-endian iOS arm64 images are supported. Unknown input never
receives an in-place rewrite; every mutation returns a freshly verified byte
string and preserves segment/section positions.
"""
from dataclasses import dataclass
import struct


class ValidationError(ValueError):
    """A packaging input or postcondition failed a required safety check."""


MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_DYLIB = 6
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
LOAD_PATH = "@executable_path/Frameworks/FocusDM.dylib"
LIBRARY_COMMANDS = {0x0C, 0x0D, 0x80000018, 0x8000001F, 0x80000023}
LINKEDIT_COMMANDS = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034}
ZERO_FILL_TYPES = {0x01, 0x0C, 0x12}


def require(condition, message):
    # Deliberately not a Python assert: safety gates still run with python -O.
    if not condition:
        raise ValidationError(message)


def checked_range(offset, size, limit, label):
    require(type(offset) is int and type(size) is int, f"{label}: non-integer range")
    require(offset >= 0 and size >= 0 and offset <= limit and size <= limit - offset,
            f"{label}: range outside image")
    return offset, offset + size


def disjoint(ranges, label):
    ordered = sorted((a, b, name) for a, b, name in ranges if b > a)
    for left, right in zip(ordered, ordered[1:]):
        require(left[1] <= right[0], f"{label}: overlapping {left[2]} and {right[2]}")


def version_number(value):
    parts = tuple(int(p) for p in str(value).split("."))
    require(1 <= len(parts) <= 3 and all(p >= 0 for p in parts), "invalid iOS version")
    parts += (0,) * (3 - len(parts))
    require(parts[0] <= 0xFFFF and parts[1] <= 0xFF and parts[2] <= 0xFF,
            "iOS version components out of range")
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def version_string(value):
    major, minor, patch = value >> 16, (value >> 8) & 0xFF, value & 0xFF
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def _name(raw):
    try:
        return raw.split(b"\0", 1)[0].decode("ascii")
    except UnicodeError as exc:
        raise ValidationError("invalid Mach-O name") from exc


def _command_string(data, offset, size, relative, label):
    require(24 <= relative < size, f"{label}: bad name offset")
    raw = data[offset + relative:offset + size]
    require(b"\0" in raw, f"{label}: unterminated name")
    try:
        name = raw.split(b"\0", 1)[0].decode("utf-8")
    except UnicodeError as exc:
        raise ValidationError(f"{label}: invalid name") from exc
    require(bool(name), f"{label}: empty name")
    return name


@dataclass(frozen=True)
class Command:
    offset: int
    kind: int
    size: int


@dataclass(frozen=True)
class Segment:
    name: str
    address: int
    virtual_size: int
    offset: int
    size: int
    protection: int


@dataclass(frozen=True)
class Section:
    segment: str
    name: str
    address: int
    size: int
    offset: int
    zero_fill: bool


@dataclass(frozen=True)
class MachO:
    data: bytes
    file_type: int
    command_bytes: int
    commands: tuple
    segments: tuple
    sections: tuple
    libraries: tuple
    minimum_ios: int
    version_command: Command

    @property
    def header_end(self):
        return 32 + self.command_bytes

    @property
    def first_section_offset(self):
        values = [s.offset for s in self.sections if not s.zero_fill and s.size]
        require(bool(values), "no file-backed section")
        return min(values)

    def address_to_offset(self, address, size=1):
        for segment in self.segments:
            delta = address - segment.address
            if 0 <= delta <= segment.size and size <= segment.size - delta:
                return segment.offset + delta
        raise ValidationError(f"address not file-backed: {address:#x}")

    def bytes_at_address(self, address, size):
        offset = self.address_to_offset(address, size)
        return self.data[offset:offset + size]

    def cstring_at_address(self, address, limit=4096):
        offset = self.address_to_offset(address)
        end = next(s.offset + s.size for s in self.segments
                   if s.offset <= offset < s.offset + s.size)
        raw = self.data[offset:min(end, offset + limit)]
        require(b"\0" in raw, f"unterminated string at {address:#x}")
        try:
            return raw.split(b"\0", 1)[0].decode("utf-8")
        except UnicodeError as exc:
            raise ValidationError(f"invalid string at {address:#x}") from exc

    def library_names(self):
        return tuple(name for kind, name in self.libraries if kind != LC_ID_DYLIB)


def parse_macho(image, expected_type=None):
    data = bytes(image)
    require(len(data) >= 32, "truncated Mach-O header")
    magic, cpu, subtype, file_type, count, size, flags, reserved = struct.unpack_from("<8I", data)
    require(magic == MH_MAGIC_64, "only thin little-endian 64-bit Mach-O is supported")
    require(cpu == CPU_TYPE_ARM64 and subtype == 0, "only arm64-all (not arm64e/simulator/x86) is supported")
    require(file_type in {MH_EXECUTE, MH_DYLIB}, "unsupported Mach-O file type")
    require(expected_type is None or file_type == expected_type, "unexpected Mach-O file type")
    require(reserved == 0 and size % 8 == 0, "invalid Mach-O header")
    checked_range(32, size, len(data), "load commands")
    require(0 < count <= size // 8, "invalid load-command count")
    header_end = 32 + size
    commands, segments, sections, libraries, versions = [], [], [], [], []
    offset = 32
    for index in range(count):
        checked_range(offset, 8, header_end, f"command {index}")
        kind, command_size = struct.unpack_from("<II", data, offset)
        require(command_size >= 8 and command_size % 8 == 0, "invalid load-command size/alignment")
        checked_range(offset, command_size, header_end, f"command {index}")
        command = Command(offset, kind, command_size)
        commands.append(command)
        if kind == LC_SEGMENT_64:
            _read_segment(data, command, segments, sections)
        elif kind in LIBRARY_COMMANDS:
            require(command_size >= 32, "truncated dylib command")
            relative = struct.unpack_from("<I", data, offset + 8)[0]
            libraries.append((kind, _command_string(data, offset, command_size, relative, "dylib")))
        elif kind == LC_BUILD_VERSION:
            require(command_size >= 24, "truncated build version")
            platform, minimum, sdk, tools = struct.unpack_from("<4I", data, offset + 8)
            require(platform == 2, "only iOS device platform is supported")
            require(command_size == 24 + tools * 8 and minimum > 0 and (not sdk or minimum <= sdk),
                    "invalid build-version command")
            versions.append((minimum, command))
        elif kind == LC_VERSION_MIN_IPHONEOS:
            require(command_size == 16, "invalid minimum-iOS command")
            minimum, sdk = struct.unpack_from("<II", data, offset + 8)
            require(minimum > 0 and (not sdk or minimum <= sdk), "invalid minimum-iOS version")
            versions.append((minimum, command))
        else:
            _validate_payload_ranges(data, command)
        offset += command_size
    require(offset == header_end, "load-command count and sizeofcmds disagree")
    require(len(versions) == 1, "one unambiguous iOS version command is required")
    require(len({s.name for s in segments}) == len(segments), "duplicate segment name")
    require(len({(s.segment, s.name) for s in sections}) == len(sections), "duplicate section name")
    disjoint([(s.offset, s.offset + s.size, s.name) for s in segments], "segments")
    disjoint([(s.address, s.address + s.virtual_size, s.name) for s in segments], "virtual segments")
    disjoint([(s.offset, s.offset + s.size, f"{s.segment},{s.name}") for s in sections if not s.zero_fill],
             "file-backed sections")
    text = [s for s in segments if s.name == "__TEXT"]
    require(len(text) == 1 and text[0].offset == 0 and text[0].size >= header_end,
            "header must be inside __TEXT")
    require(text[0].protection & 4, "__TEXT is not executable")
    names = [name for kind, name in libraries if kind != LC_ID_DYLIB]
    require(len(names) == len(set(names)), "duplicate library load commands")
    ids = [name for kind, name in libraries if kind == LC_ID_DYLIB]
    require(len(ids) == (1 if file_type == MH_DYLIB else 0), "invalid dylib identifier commands")
    parsed = MachO(data, file_type, size, tuple(commands), tuple(segments), tuple(sections),
                   tuple(libraries), versions[0][0], versions[0][1])
    require(parsed.first_section_offset >= header_end, "section overlaps load commands")
    return parsed


def _read_segment(data, command, segments, sections):
    offset, size = command.offset, command.size
    require(size >= 72, "truncated segment command")
    name = _name(data[offset + 8:offset + 24])
    address, virtual_size, file_offset, file_size, max_prot, protection, count, flags = struct.unpack_from(
        "<4Q4I", data, offset + 24)
    require(size == 72 + count * 80, "segment section count/size mismatch")
    checked_range(file_offset, file_size, len(data), f"segment {name}")
    require(file_size <= virtual_size and address + virtual_size <= 1 << 64, "invalid segment extent")
    segments.append(Segment(name, address, virtual_size, file_offset, file_size, protection))
    for index in range(count):
        pos = offset + 72 + index * 80
        sec_name, sec_segment = _name(data[pos:pos + 16]), _name(data[pos + 16:pos + 32])
        sec_address, sec_size, sec_offset, align, reloc, reloc_count, sec_flags = struct.unpack_from(
            "<2Q5I", data, pos + 32)
        zero_fill = (sec_flags & 0xFF) in ZERO_FILL_TYPES
        require(sec_segment == name, "section and segment names disagree")
        require(address <= sec_address <= address + virtual_size and
                sec_size <= address + virtual_size - sec_address, "section outside virtual segment")
        require(align < 32, "invalid section alignment")
        if not zero_fill and sec_size:
            checked_range(sec_offset, sec_size, len(data), f"section {sec_name}")
            require(file_offset <= sec_offset and sec_offset + sec_size <= file_offset + file_size,
                    "section outside file-backed segment")
            require(sec_offset % (1 << align) == 0, "misaligned section")
        elif zero_fill:
            require(sec_offset == 0, "zero-fill section has a file offset")
        if reloc_count:
            checked_range(reloc, reloc_count * 8, len(data), "section relocations")
        sections.append(Section(name, sec_name, sec_address, sec_size, sec_offset, zero_fill))


def _validate_payload_ranges(data, command):
    offset, kind, size = command.offset, command.kind, command.size
    if kind in LINKEDIT_COMMANDS:
        require(size == 16, "invalid linkedit-data command")
        checked_range(*struct.unpack_from("<II", data, offset + 8), len(data), "linkedit data")
    elif kind == 0x02:  # LC_SYMTAB: 64-bit nlist entries are 16 bytes.
        require(size == 24, "invalid symbol-table command")
        symbols, count, strings, string_size = struct.unpack_from("<4I", data, offset + 8)
        checked_range(symbols, count * 16, len(data), "symbol table")
        checked_range(strings, string_size, len(data), "string table")
    elif kind in {0x22, 0x80000022}:  # LC_DYLD_INFO[_ONLY]
        require(size == 48, "invalid dyld-info command")
        for pos in range(offset + 8, offset + 48, 8):
            checked_range(*struct.unpack_from("<II", data, pos), len(data), "dyld info")
    elif kind == 0x2C:  # LC_ENCRYPTION_INFO_64
        require(size == 24, "invalid encryption-info command")
        start, length, encrypted = struct.unpack_from("<3I", data, offset + 8)
        checked_range(start, length, len(data), "encrypted data")
        require(encrypted == 0, "encrypted executables are not supported")
    elif kind == 0x80000028:  # LC_MAIN
        require(size == 24, "invalid main-entry command")
        entry = struct.unpack_from("<Q", data, offset + 8)[0]
        checked_range(entry, 1, len(data), "entry point")


def validate_dylib(data, load_path=LOAD_PATH):
    image = parse_macho(data, MH_DYLIB)
    identity = next(name for kind, name in image.libraries if kind == LC_ID_DYLIB)
    require(identity == load_path, "dylib install_name does not match load path")
    require(image.minimum_ios >= version_number("14.0"), "dylib must target iOS 14 or newer")
    return image


def inject_load_dylib(data, load_path=LOAD_PATH):
    before = parse_macho(data, MH_EXECUTE)
    require(load_path not in before.library_names(), "FocusDM already injected; refusing reinjection")
    require(load_path == LOAD_PATH, "unsupported injected library identity")
    encoded = load_path.encode("utf-8") + b"\0"
    size = (24 + len(encoded) + 7) & ~7
    start, end = checked_range(before.header_end, size, len(before.data), "injection window")
    require(end <= before.first_section_offset, "no room before first section")
    require(not any(before.data[start:end]), "injection window contains code/data; refusing overwrite")
    result = bytearray(before.data)
    command = struct.pack("<6I", LC_LOAD_DYLIB, size, 24, 2, 0x10000, 0x10000) + encoded
    result[start:end] = command.ljust(size, b"\0")
    struct.pack_into("<II", result, 16, len(before.commands) + 1, before.command_bytes + size)
    after = parse_macho(result, MH_EXECUTE)
    require(len(result) == len(before.data), "injection moved image bytes")
    require(after.segments == before.segments and after.sections == before.sections, "injection changed layout")
    require(after.library_names() == before.library_names() + (load_path,), "unexpected library mutation")
    require(after.data[32:before.header_end] == before.data[32:before.header_end] and
            after.data[end:] == before.data[end:], "injection changed unrelated bytes")
    return after.data


def set_minimum_ios(data, minimum):
    before = parse_macho(data, MH_EXECUTE)
    require(minimum >= before.minimum_ios, "refusing to lower minimum iOS")
    command = before.version_command
    pos = command.offset + (12 if command.kind == LC_BUILD_VERSION else 8)
    result = bytearray(before.data)
    struct.pack_into("<I", result, pos, minimum)
    after = parse_macho(result, MH_EXECUTE)
    require(after.minimum_ios == minimum and after.segments == before.segments and
            after.sections == before.sections, "minimum-iOS update changed layout")
    return after.data
