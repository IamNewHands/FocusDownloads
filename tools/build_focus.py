"""Build a new, unsigned Focus v19+ IPA from the SHA-locked original.

No defaults point at an old IPA or a mutable downloaded library. All inputs,
source identity and a *new* output path must be supplied explicitly. A validated
in-memory package is produced first, and existing output files are never opened
for writing. LCSign remains responsible for signing the new package.
"""
import argparse
from copy import copy
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import struct
import sys
import zipfile

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from tools.focus_patches import (ORIGINAL_IPA_SHA256, apply_patch_manifest,
        assert_allowed_differences, canonical_json, load_patch_manifest, sha256)
    from tools.provenance import new_output_path, validate_provenance
    from tools.safe_macho import (LC_BUILD_VERSION, LOAD_PATH, MH_EXECUTE, ValidationError,
        inject_load_dylib, parse_macho, require, set_minimum_ios, validate_dylib, version_string)
else:
    from .focus_patches import (ORIGINAL_IPA_SHA256, apply_patch_manifest,
        assert_allowed_differences, canonical_json, load_patch_manifest, sha256)
    from .provenance import new_output_path, validate_provenance
    from .safe_macho import (LC_BUILD_VERSION, LOAD_PATH, MH_EXECUTE, ValidationError,
        inject_load_dylib, parse_macho, require, set_minimum_ios, validate_dylib, version_string)

EXE_MEMBER = "Payload/PPBrowser.app/PPBrowser"
INFO_MEMBER = "Payload/PPBrowser.app/Info.plist"
LIBRARY_MEMBER = "Payload/PPBrowser.app/Frameworks/FocusDM.dylib"
PROVENANCE_MEMBER = "Payload/PPBrowser.app/FocusDM.provenance.json"
MAX_MEMBER_SIZE = 128 * 1024 * 1024
MAX_ARCHIVE_CONTENT = 512 * 1024 * 1024


def validate_archive(archive):
    names = archive.namelist()
    require(len(names) == len(set(names)), "archive contains duplicate entries")
    require(sum(info.file_size for info in archive.infolist()) <= MAX_ARCHIVE_CONTENT,
            "archive expanded size is too large")
    for info in archive.infolist():
        name = info.filename
        path = PurePosixPath(name)
        require(name and not path.is_absolute() and ".." not in path.parts and
                "\\" not in name and not name.startswith("/") and
                not any(":" in part for part in path.parts), "unsafe archive member path")
        require(not info.flag_bits & 1, "encrypted archive entries are not supported")
        require(info.file_size <= MAX_MEMBER_SIZE, "archive member is too large")
    require(archive.testzip() is None, "ZIP integrity check failed")


def prepare_executable(original, library_image, patch_manifest):
    original_image = parse_macho(original, MH_EXECUTE)
    business = apply_patch_manifest(original, patch_manifest)
    injected = inject_load_dylib(business)
    if patch_manifest.get("reference_v18_executable_sha256"):
        require(sha256(injected) == patch_manifest["reference_v18_executable_sha256"],
                "existing v18 patch/load-command baseline changed")
    minimum = library_image.minimum_ios
    updated = set_minimum_ios(injected, minimum)
    version = original_image.version_command
    version_offset = version.offset + (12 if version.kind == LC_BUILD_VERSION else 8)
    allowed = [(patch["offset"], patch["size"]) for patch in patch_manifest["patches"]]
    injection_size = len(injected) - len(original)  # Always zero: load command fits existing padding.
    require(injection_size == 0, "injection changed binary length")
    command_size = parse_macho(injected).header_end - original_image.header_end
    allowed += [(16, 8), (original_image.header_end, command_size), (version_offset, 4)]
    assert_allowed_differences(original, updated, allowed)
    after = parse_macho(updated, MH_EXECUTE)
    require(after.minimum_ios == minimum and after.library_names().count(LOAD_PATH) == 1,
            "executable platform/injection readback failed")
    return updated


def _package_provenance(source, patch_manifest, original_ipa, executable, library):
    fields = ("schema_version", "patch_version", "source_sha", "library_sha256", "library_size",
              "install_name", "minimum_ios", "embedded_build_metadata", "source_files", "source_manifest_sha256")
    result = {field:source[field] for field in fields}
    result.update({
        "original_ipa_sha256":sha256(original_ipa),
        "original_executable_sha256":patch_manifest["original_executable_sha256"],
        "patched_executable_sha256":sha256(executable),
        "patch_manifest_sha256":sha256(canonical_json(patch_manifest)),
        "patch_baseline":"Focus 2.9.7 reviewed v1-v18 patches, unchanged",
        "unsigned_requires_resigning":True,
    })
    require(result["library_sha256"] == sha256(library), "package library provenance mismatch")
    return result


def assemble_package(original_ipa, library, provenance, source_root):
    """All transformations and validation happen in memory; no files are written."""
    require(sha256(original_ipa) == ORIGINAL_IPA_SHA256, "original IPA SHA-256 mismatch; patched inputs are refused")
    patch_manifest = load_patch_manifest()
    library_image = validate_provenance(provenance, library, source_root)
    with zipfile.ZipFile(io.BytesIO(original_ipa)) as source:
        validate_archive(source)
        require(EXE_MEMBER in source.namelist() and INFO_MEMBER in source.namelist(), "original app members are missing")
        require(LIBRARY_MEMBER not in source.namelist() and PROVENANCE_MEMBER not in source.namelist(),
                "already-injected source is not supported")
        original_executable = source.read(EXE_MEMBER)
        executable = prepare_executable(original_executable, library_image, patch_manifest)
        original_info = source.read(INFO_MEMBER)
        information = plistlib.loads(original_info)
        require(isinstance(information, dict), "Info.plist is not a dictionary")
        require(information.get("CFBundleIdentifier") == "com.qingbin.focusbrowser" and
                information.get("CFBundleShortVersionString") == "2.9.7", "original app identity mismatch")
        information["MinimumOSVersion"] = version_string(library_image.minimum_ios)
        format_kind = plistlib.FMT_BINARY if original_info.startswith(b"bplist") else plistlib.FMT_XML
        new_info = plistlib.dumps(information, fmt=format_kind, sort_keys=False)
        package_provenance = _package_provenance(provenance, patch_manifest, original_ipa, executable, library)
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as output:
            output.comment = source.comment
            for info in source.infolist():
                data = executable if info.filename == EXE_MEMBER else new_info if info.filename == INFO_MEMBER else source.read(info)
                output.writestr(copy(info), data)
            for name, data, permissions in (
                (LIBRARY_MEMBER, library, 0o100755),
                (PROVENANCE_MEMBER, canonical_json(package_provenance) + b"\n", 0o100644),
            ):
                info = zipfile.ZipInfo(name, date_time=(2026, 11, 8, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = permissions << 16
                output.writestr(info, data)
        result = stream.getvalue()
    verify_package(original_ipa, result, library, package_provenance, patch_manifest)
    # Detect source mutation while the package was being assembled.
    validate_provenance(provenance, library, source_root)
    return result


def verify_package(original_ipa, result, library, provenance, patch_manifest):
    with zipfile.ZipFile(io.BytesIO(original_ipa)) as original, zipfile.ZipFile(io.BytesIO(result)) as output:
        validate_archive(output)
        original_names, output_names = set(original.namelist()), set(output.namelist())
        require(output_names - original_names == {LIBRARY_MEMBER, PROVENANCE_MEMBER} and
                not original_names - output_names, "unexpected package members")
        require(len(output.namelist()) == len(original.namelist()) + 2, "package entry-count mismatch")
        for name in original.namelist():
            if name not in {EXE_MEMBER, INFO_MEMBER}:
                require(output.read(name) == original.read(name), f"unrelated resource changed: {name}")
            old, new = original.getinfo(name), output.getinfo(name)
            require((old.compress_type, old.external_attr, old.internal_attr, old.create_system,
                     old.date_time, old.comment, old.extra) ==
                    (new.compress_type, new.external_attr, new.internal_attr, new.create_system,
                     new.date_time, new.comment, new.extra), f"resource metadata changed: {name}")
        require(output.comment == original.comment, "archive comment changed")
        require(output.read(LIBRARY_MEMBER) == library, "injected library bytes differ")
        loaded = json.loads(output.read(PROVENANCE_MEMBER))
        require(loaded == provenance, "package provenance readback differs")
        executable = output.read(EXE_MEMBER)
        require(sha256(executable) == provenance["patched_executable_sha256"], "executable hash readback differs")
        image = parse_macho(executable, MH_EXECUTE)
        info = plistlib.loads(output.read(INFO_MEMBER))
        original_info = plistlib.loads(original.read(INFO_MEMBER))
        original_info["MinimumOSVersion"] = provenance["minimum_ios"]
        require(info == original_info and info["MinimumOSVersion"] == version_string(image.minimum_ios),
                "Info.plist changed outside the minimum-iOS contract")
        require(image.library_names().count(LOAD_PATH) == 1, "library injection missing/duplicated")
        require(len(executable) == len(original.read(EXE_MEMBER)), "executable size changed")
        expected = prepare_executable(original.read(EXE_MEMBER), validate_dylib(library), patch_manifest)
        require(executable == expected, "executable full readback differs from permitted patches")


def write_new_package(path, data):
    """Exclusive creation; remove only our own new partial file on write failure."""
    created_identity = None
    try:
        with path.open("xb") as handle:
            status = os.fstat(handle.fileno())
            created_identity = (status.st_dev, status.st_ino)
            require(handle.write(data) == len(data), "incomplete IPA write")
            handle.flush()
            os.fsync(handle.fileno())
        require(path.read_bytes() == data, "IPA disk readback failed")
    except BaseException:
        if created_identity is not None:
            try:
                status = path.stat()
                if (status.st_dev, status.st_ino) == created_identity:
                    path.unlink()
            except OSError:
                pass
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, help="The reviewed, unmodified Focus_2.9.7.ipa")
    parser.add_argument("--dylib", required=True, help="A new v19+ library with compiled build metadata")
    parser.add_argument("--provenance", required=True, help="CI-generated library/source manifest")
    parser.add_argument("--source-root", required=True, help="The exact source tree used to compile the library")
    parser.add_argument("--out", required=True, help="An output IPA path that does not exist")
    options = parser.parse_args(argv)
    try:
        output = new_output_path(options.out, [options.ipa, options.dylib, options.provenance])
        require(output.suffix.lower() == ".ipa", "output filename must end with .ipa")
        original = Path(options.ipa).read_bytes()
        library = Path(options.dylib).read_bytes()
        provenance = json.loads(Path(options.provenance).read_text(encoding="utf-8"))
        result = assemble_package(original, library, provenance, options.source_root)
        require(Path(options.dylib).read_bytes() == library, "library input changed during packaging")
        validate_provenance(provenance, library, options.source_root)
        write_new_package(output, result)
        print(f"Verified unsigned package: {output}; {provenance['patch_version']} source={provenance['source_sha']}")
        print(f"IPA SHA-256: {sha256(result)}; resign with LCSign before installation")
        return 0
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile) as exc:
        parser.exit(2, f"Package rejected: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
