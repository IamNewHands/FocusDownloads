"""Apply the reviewed, SHA-bound Focus 2.9.7 binary patch manifest in memory."""
import hashlib
import json
from pathlib import Path
import struct

from .safe_macho import MH_EXECUTE, checked_range, disjoint, parse_macho, require

ORIGINAL_IPA_SHA256 = "377d37baf421ca90819a1a1624498be7776e553bb982a55f1a1173425ab9ae71"
ORIGINAL_EXE_SHA256 = "6af11eb309cc7f2d75bd87ddaf4f6fb231305825a876678ae1414e2b7fcf424c"
REFERENCE_V18_EXE_SHA256 = "566f5827bffcb4cda278361dd8c2b8dfba1441af9e904ec220b244adfe201e87"
MANIFEST_PATH = Path(__file__).with_name("focus_2_9_7_patches.json")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def load_patch_manifest():
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    require(manifest.get("schema_version") == 1, "unsupported patch-manifest schema")
    require(manifest.get("original_ipa_sha256") == ORIGINAL_IPA_SHA256 and
            manifest.get("original_executable_sha256") == ORIGINAL_EXE_SHA256,
            "patch manifest is not bound to the reviewed original")
    require(manifest.get("reference_v18_executable_sha256") == REFERENCE_V18_EXE_SHA256,
            "patch manifest has a different v18 reference")
    return manifest


def validate_manifest_identity(manifest, original):
    require(len(original) == manifest["executable_size"], "original executable size mismatch")
    require(sha256(original) == manifest["original_executable_sha256"], "original executable SHA-256 mismatch")
    image = parse_macho(original, MH_EXECUTE)
    for item in manifest["methods"]:
        entry = item["entry_address"]
        pointers = struct.unpack("<QQQ", image.bytes_at_address(entry, 24))
        selector, types, implementation = pointers
        require(image.cstring_at_address(selector) == item["old_selector"], "original selector identity mismatch")
        require(image.cstring_at_address(types) == item["types"], "original method ABI mismatch")
        require(implementation == item["old_implementation"], "original method implementation mismatch")
    return image


def apply_patch_manifest(original, manifest):
    image = validate_manifest_identity(manifest, original)
    result = bytearray(original)
    ranges = []
    identifiers = set()
    for patch in manifest["patches"]:
        identifier, offset = patch["id"], patch["offset"]
        require(identifier not in identifiers, "duplicate patch identifier")
        identifiers.add(identifier)
        old, new = bytes.fromhex(patch["old_hex"]), bytes.fromhex(patch["new_hex"])
        require(bool(old) and len(old) == len(new) and patch.get("size") == len(old),
                "patch must have a complete equal-length preimage with an exact declared size")
        start, end = checked_range(offset, len(old), len(original), identifier)
        require(start >= image.header_end, "business patch must not rewrite header/load commands")
        require(original[start:end] == old, f"complete preimage mismatch for {identifier}")
        if patch.get("code_cave"):
            require(end <= image.first_section_offset and not any(old), "code cave is not empty header padding")
        ranges.append((start, end, identifier))
        result[start:end] = new
    disjoint(ranges, "patches")
    require(len(result) == len(original), "patch changed executable size")
    require(sha256(result) == manifest["business_patched_executable_sha256"], "patched executable SHA-256 mismatch")
    require(sum(a != b for a, b in zip(original, result)) == manifest["business_diff_bytes"],
            "unexpected binary patch difference count")
    after = parse_macho(result, MH_EXECUTE)
    require(after.segments == image.segments and after.sections == image.sections, "patch changed Mach-O layout")
    for method in manifest["methods"]:
        selector, types, implementation = struct.unpack("<QQQ", after.bytes_at_address(method["entry_address"], 24))
        require(after.cstring_at_address(selector) == method["new_selector"] and
                after.cstring_at_address(types) == method["types"] and
                implementation == method["new_implementation"], "patched method metadata readback mismatch")
    return bytes(result)


def assert_allowed_differences(before, after, ranges):
    require(len(before) == len(after), "executable length changed")
    checked = []
    for offset, length in ranges:
        start, end = checked_range(offset, length, len(before), "allowed mutation")
        checked.append((start, end))
    checked.sort()
    index = 0
    for start, end in checked:
        require(before[index:start] == after[index:start], "unlisted executable mutation")
        index = max(index, end)
    require(before[index:] == after[index:], "unlisted executable mutation")
