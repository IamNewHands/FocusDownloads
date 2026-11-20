"""Packaging regressions use synthetic in-memory fixtures, never real IPA writes."""
from copy import copy, deepcopy
import io
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

from tools import build_focus, focus_patches, provenance, safe_macho

BASE = 0x100000000
REVISION = "3e566c4569e2866cd991097494ca1f3bbb4f64d7"


def _segment(name, address, offset, size, section_name="__text", section_offset=0x1000):
    section_size = 0x100
    body = struct.pack("<16s4Q4I", name.encode(), address, size, offset, size, 5, 5, 1, 0)
    section = struct.pack("<16s16s2Q8I", section_name.encode(), name.encode(),
                          address + section_offset - offset, section_size, section_offset,
                          0, 0, 0, 0x80000400, 0, 0, 0)
    return struct.pack("<II", 0x19, 152) + body + section


def _dylib_command(kind, name):
    name = name.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    return (struct.pack("<6I", kind, size, 24, 2, 0x10000, 0x10000) + name).ljust(size, b"\0")


def macho_fixture(file_type=safe_macho.MH_EXECUTE, minimum="13.0", load=None, metadata=None):
    commands = [_segment("__TEXT", BASE, 0, 0x2000),
                struct.pack("<6I", 0x32, 24, 2, safe_macho.version_number(minimum),
                            safe_macho.version_number("17.0"), 0)]
    if file_type == safe_macho.MH_DYLIB:
        commands.append(_dylib_command(0x0D, safe_macho.LOAD_PATH))
    if load is not None:
        commands.append(_dylib_command(0x0C, load))
    data = bytearray(0x2000)
    struct.pack_into("<8I", data, 0, safe_macho.MH_MAGIC_64, safe_macho.CPU_TYPE_ARM64,
                     0, file_type, len(commands), sum(map(len, commands)), 0, 0)
    payload = b"".join(commands)
    data[32:32 + len(payload)] = payload
    data[0x1000:0x1004] = bytes.fromhex("c0035fd6")
    if metadata is not None:
        marker = provenance.BUILD_METADATA_PREFIX + focus_patches.canonical_json(metadata) + b"\0"
        data[0x1040:0x1040 + len(marker)] = marker
    return bytes(data)


def embedded_identity(version="v19", revision=REVISION):
    return {"schema_version":1, "patch_version":version, "source_sha":revision}


def patch_fixture():
    original = bytearray(macho_fixture())
    original[0x1100:0x1104] = b"old!"
    original[0x1180:0x1184] = b"sel\0"
    original[0x1190:0x1198] = b"v16@0:8\0"
    struct.pack_into("<3Q", original, 0x1200, BASE + 0x1180, BASE + 0x1190, BASE + 0x1000)
    updated = bytearray(original)
    updated[0x1100:0x1104] = b"new!"
    method = {"owner":"Fixture", "entry_address":BASE + 0x1200, "old_selector":"sel",
              "new_selector":"sel", "types":"v16@0:8", "old_implementation":BASE + 0x1000,
              "new_implementation":BASE + 0x1000}
    manifest = {"executable_size":len(original), "original_executable_sha256":focus_patches.sha256(original),
                "business_patched_executable_sha256":focus_patches.sha256(updated), "business_diff_bytes":3,
                "patches":[{"id":"fixture", "offset":0x1100, "size":4,
                            "old_hex":b"old!".hex(), "new_hex":b"new!".hex(), "code_cave":False}],
                "methods":[method]}
    return bytes(original), bytes(updated), manifest


def zip_fixture(executable, resources=None):
    stream = io.BytesIO()
    information = {"CFBundleIdentifier":"com.qingbin.focusbrowser", "CFBundleShortVersionString":"2.9.7",
                   "CFBundleVersion":"1", "MinimumOSVersion":"13.0", "UIFileSharingEnabled":True}
    entries = [(build_focus.EXE_MEMBER, executable),
               (build_focus.INFO_MEMBER, plistlib.dumps(information)),
               ("Payload/PPBrowser.app/resource.txt", b"unchanged resource")]
    entries.extend(resources or [])
    with zipfile.ZipFile(stream, "w") as archive:
        archive.comment = b"fixture archive"
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 4, 1, 2, 4))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.comment = b"entry fixture"
            archive.writestr(info, data)
    return stream.getvalue()


class MachOTests(unittest.TestCase):
    def test_parses_valid_executable_and_library(self):
        self.assertEqual(safe_macho.parse_macho(macho_fixture()).first_section_offset, 0x1000)
        image = safe_macho.validate_dylib(macho_fixture(safe_macho.MH_DYLIB, "14.0"))
        self.assertEqual(safe_macho.version_string(image.minimum_ios), "14.0")

    def test_rejects_magic_cpu_and_file_type(self):
        for offset, value in [(0, 0xCAFEBABE), (4, 0x01000007), (8, 2), (12, 1), (28, 1)]:
            with self.subTest(offset=offset):
                data = bytearray(macho_fixture())
                struct.pack_into("<I", data, offset, value)
                with self.assertRaises(safe_macho.ValidationError): safe_macho.parse_macho(data)

    def test_rejects_truncated_command_size_and_count(self):
        for offset, value in [(20, 0x3000), (16, 3), (36, 7), (36, 0x4000), (36, 160)]:
            with self.subTest(offset=offset, value=value):
                data = bytearray(macho_fixture())
                struct.pack_into("<I", data, offset, value)
                with self.assertRaises(safe_macho.ValidationError): safe_macho.parse_macho(data)

    def test_rejects_section_range_overlap_and_platform(self):
        for offset, value in [(32 + 72 + 48, 0x3000), (32 + 152 + 8, 7),
                              (32 + 72 + 48, 32), (32 + 72 + 52, 32)]:
            with self.subTest(offset=offset):
                data = bytearray(macho_fixture())
                struct.pack_into("<I", data, offset, value)
                with self.assertRaises(safe_macho.ValidationError): safe_macho.parse_macho(data)

    def test_injection_preserves_layout_and_length(self):
        original = macho_fixture()
        before = safe_macho.parse_macho(original)
        result = safe_macho.inject_load_dylib(original)
        after = safe_macho.parse_macho(result)
        self.assertEqual(len(result), len(original))
        self.assertEqual(before.sections, after.sections)
        self.assertEqual(after.library_names(), (safe_macho.LOAD_PATH,))
        self.assertEqual(after.data[0x1000:], original[0x1000:])

    def test_injection_rejects_nonzero_cave_and_duplicate(self):
        data = bytearray(macho_fixture())
        data[safe_macho.parse_macho(data).header_end + 10] = 1
        with self.assertRaisesRegex(safe_macho.ValidationError, "contains code/data"):
            safe_macho.inject_load_dylib(data)
        with self.assertRaisesRegex(safe_macho.ValidationError, "reinjection"):
            safe_macho.inject_load_dylib(safe_macho.inject_load_dylib(macho_fixture()))

    def test_injection_rejects_missing_room(self):
        data = bytearray(macho_fixture())
        start = safe_macho.parse_macho(data).header_end
        struct.pack_into("<Q", data, 32 + 72 + 32, BASE + start + 8)
        struct.pack_into("<I", data, 32 + 72 + 48, start + 8)
        with self.assertRaisesRegex(safe_macho.ValidationError, "no room"):
            safe_macho.inject_load_dylib(data)

    def test_library_rejects_wrong_identity_and_ios13(self):
        data = bytearray(macho_fixture(safe_macho.MH_DYLIB, "14.0"))
        identity = safe_macho.parse_macho(data).commands[-1]
        data[identity.offset + 24] = ord("/")
        with self.assertRaisesRegex(safe_macho.ValidationError, "install_name"):
            safe_macho.validate_dylib(data)
        with self.assertRaisesRegex(safe_macho.ValidationError, "iOS 14"):
            safe_macho.validate_dylib(macho_fixture(safe_macho.MH_DYLIB, "13.0"))

    def test_minimum_ios_only_changes_version_field(self):
        original = macho_fixture()
        result = safe_macho.set_minimum_ios(original, safe_macho.version_number("14.0"))
        version = safe_macho.parse_macho(original).version_command.offset + 12
        focus_patches.assert_allowed_differences(original, result, [(version, 4)])
        self.assertEqual(safe_macho.parse_macho(result).minimum_ios, safe_macho.version_number("14.0"))
        with self.assertRaises(safe_macho.ValidationError):
            safe_macho.set_minimum_ios(result, safe_macho.version_number("13.0"))


class PatchManifestTests(unittest.TestCase):
    def test_complete_patch_and_metadata_pass(self):
        original, expected, manifest = patch_fixture()
        self.assertEqual(focus_patches.apply_patch_manifest(original, manifest), expected)

    def test_checks_bytes_beyond_old_partial_prefix(self):
        original, expected, manifest = patch_fixture()
        manifest["patches"][0]["old_hex"] = b"old?".hex()
        with self.assertRaisesRegex(safe_macho.ValidationError, "complete preimage"):
            focus_patches.apply_patch_manifest(original, manifest)

    def test_rejects_size_mismatch_overlap_and_header_patch(self):
        for change in ("size", "overlap", "header"):
            with self.subTest(change=change):
                original, expected, manifest = patch_fixture()
                if change == "size": manifest["patches"][0]["size"] = 3
                if change == "overlap":
                    duplicate = dict(manifest["patches"][0]); duplicate["id"] = "overlapping"
                    manifest["patches"].append(duplicate)
                if change == "header": manifest["patches"][0]["offset"] = 16
                with self.assertRaises(safe_macho.ValidationError):
                    focus_patches.apply_patch_manifest(original, manifest)

    def test_rejects_selector_types_and_implementation_mismatch(self):
        for field, value in [("old_selector", "wrong"), ("types", "v32@0:8@16@24"),
                             ("old_implementation", BASE + 0x1100)]:
            with self.subTest(field=field):
                original, expected, manifest = patch_fixture()
                manifest["methods"][0][field] = value
                with self.assertRaises(safe_macho.ValidationError):
                    focus_patches.apply_patch_manifest(original, manifest)

    def test_rejects_original_hash_and_patched_hash_mismatch(self):
        original, expected, manifest = patch_fixture()
        for field in ("original_executable_sha256", "business_patched_executable_sha256"):
            bad = deepcopy(manifest); bad[field] = "0" * 64
            with self.subTest(field=field), self.assertRaises(safe_macho.ValidationError):
                focus_patches.apply_patch_manifest(original, bad)

    def test_manifest_has_full_metadata_and_preserved_patch_scope(self):
        manifest = focus_patches.load_patch_manifest()
        self.assertEqual(manifest["business_diff_bytes"], 383)
        self.assertEqual(manifest["reference_total_diff_bytes"], 432)
        self.assertEqual(len(manifest["patches"]), 20)
        for item in manifest["patches"]:
            self.assertEqual(item["size"], len(bytes.fromhex(item["old_hex"])))
            self.assertEqual(item["size"], len(bytes.fromhex(item["new_hex"])))
        metadata = [p for p in manifest["patches"] if p["id"].endswith("-method")]
        self.assertEqual([p["size"] for p in metadata], [24, 24])


class GitCommitFixture:
    """Only substitutes local Git reads; source files and safety checks stay real."""
    def __init__(self, root, revision, files):
        self.root = Path(root).resolve()
        self.revision = revision
        self.blobs = {}
        records = []
        for name, contents in sorted(files.items()):
            object_id = hashlib.sha1(b"blob " + str(len(contents)).encode() + b"\0" + contents).hexdigest()
            self.blobs[object_id] = contents
            records.append(f"100644 blob {object_id}\t{name}".encode() + b"\0")
        self.tree = b"".join(records)

    def read(self, root, *arguments):
        if arguments == ("rev-parse", "--show-toplevel"):
            return str(self.root).encode() + b"\n"
        if arguments == ("rev-parse", "--verify", "HEAD"):
            return self.revision.encode() + b"\n"
        if arguments == ("ls-tree", "-r", "-z", self.revision, "--", "src"):
            return self.tree
        if len(arguments) == 3 and arguments[0:2] == ("cat-file", "blob"):
            return self.blobs[arguments[2]]
        raise AssertionError(f"unexpected local Git read: {arguments!r}")


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        # Use a per-test new directory; existing artifacts are never written.
        root = Path(os.environ.get("FOCUS_TEST_TMP", Path(__file__).resolve().parent))
        self.temp = tempfile.TemporaryDirectory(prefix=".packaging-test-", dir=root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        (self.root / "src" / "FocusDM.m").write_text("// fixture source\n", encoding="utf-8")
        (self.root / "src" / "FDMCommon.h").write_text("// fixture header\n", encoding="utf-8")
        self.commit = GitCommitFixture(self.root, REVISION, {
            "src/FDMCommon.h":(self.root / "src" / "FDMCommon.h").read_bytes(),
            "src/FocusDM.m":(self.root / "src" / "FocusDM.m").read_bytes(),
        })
        reader = patch.object(provenance, "_git_read", side_effect=self.commit.read)
        reader.start()
        self.addCleanup(reader.stop)
        self.library = macho_fixture(safe_macho.MH_DYLIB, "14.0", metadata=embedded_identity())
        self.value = provenance.create_provenance(self.library, self.root, "v19", REVISION)

    def test_library_manifest_and_current_sources_pass(self):
        image = provenance.validate_provenance(self.value, self.library, self.root)
        self.assertEqual(image.minimum_ios, safe_macho.version_number("14.0"))
        self.assertEqual([x["path"] for x in self.value["source_files"]], ["src/FDMCommon.h", "src/FocusDM.m"])

    def test_rejects_manifest_claim_not_compiled_into_library(self):
        with self.assertRaisesRegex(safe_macho.ValidationError, "compiled library"):
            provenance.create_provenance(self.library, self.root, "v19", "1" * 40)
        with self.assertRaisesRegex(safe_macho.ValidationError, "no compiled"):
            provenance.create_provenance(macho_fixture(safe_macho.MH_DYLIB, "14.0"), self.root, "v19", REVISION)

    def test_rejects_wrong_checkout_even_with_matching_library_metadata(self):
        self.commit.revision = "1" * 40
        with self.assertRaisesRegex(safe_macho.ValidationError, "checked-out HEAD"):
            provenance.create_provenance(self.library, self.root, "v19", REVISION)

    def test_rejects_missing_committed_module(self):
        # Deletes only this test's new temporary fixture, never a repository source.
        (self.root / "src" / "FDMCommon.h").unlink()
        with self.assertRaisesRegex(safe_macho.ValidationError, "claimed Git commit"):
            provenance.validate_provenance(self.value, self.library, self.root)

    def test_rejects_symlink_nested_and_submodule_commit_entries(self):
        for record in (
            b"120000 blob " + b"1" * 40 + b"\tsrc/linked.m\0",
            b"100644 blob " + b"1" * 40 + b"\tsrc/nested/engine.m\0",
            b"160000 commit " + b"1" * 40 + b"\tsrc/submodule\0",
        ):
            self.commit.tree = record
            with self.subTest(record=record), self.assertRaises(safe_macho.ValidationError):
                provenance.source_file_manifest_for_revision(self.root, REVISION)

    def test_rejects_changed_source_or_new_missing_module(self):
        (self.root / "src" / "FDMEngine.m").write_text("// new module\n", encoding="utf-8")
        with self.assertRaisesRegex(safe_macho.ValidationError, "current source tree"):
            provenance.validate_provenance(self.value, self.library, self.root)

    def test_rejects_same_names_with_changed_content(self):
        (self.root / "src" / "FocusDM.m").write_text("// changed\n", encoding="utf-8")
        with self.assertRaisesRegex(safe_macho.ValidationError, "current source tree"):
            provenance.validate_provenance(self.value, self.library, self.root)

    def test_rejects_hash_identity_and_source_manifest_tampering(self):
        for field, value in [("library_sha256", "0" * 64), ("source_sha", "1" * 40),
                             ("source_manifest_sha256", "0" * 64), ("minimum_ios", "13.0")]:
            bad = deepcopy(self.value); bad[field] = value
            with self.subTest(field=field), self.assertRaises(safe_macho.ValidationError):
                provenance.validate_provenance(bad, self.library, self.root)

    def test_rejects_conflicting_compiled_metadata(self):
        bad = bytearray(self.library)
        marker = provenance.BUILD_METADATA_PREFIX + focus_patches.canonical_json(embedded_identity("v20")) + b"\0"
        bad[0x1600:0x1600 + len(marker)] = marker
        with self.assertRaisesRegex(safe_macho.ValidationError, "conflicting"):
            provenance.embedded_build_metadata(bad)

    def test_rejects_legacy_unversioned_and_local_revision(self):
        for version, revision in [("v18", REVISION), ("v19", "local-uncompiled"), ("19", REVISION)]:
            with self.subTest(version=version, revision=revision), self.assertRaises(safe_macho.ValidationError):
                provenance.validate_build_identity(version, revision)

    def test_existing_output_is_not_overwritten(self):
        output = self.root / "old.ipa"
        output.write_bytes(b"old artifact")
        with self.assertRaisesRegex(safe_macho.ValidationError, "overwrite"):
            provenance.new_output_path(output)
        self.assertEqual(output.read_bytes(), b"old artifact")
        with self.assertRaises(FileExistsError): build_focus.write_new_package(output, b"new artifact")
        self.assertEqual(output.read_bytes(), b"old artifact")

    def test_provenance_writer_roundtrip_and_existing_output_protection(self):
        output = self.root / "new.provenance.json"
        provenance.write_new_provenance(output, self.value)
        self.assertEqual(json.loads(output.read_bytes()), self.value)
        existing = output.read_bytes()
        with self.assertRaises(FileExistsError):
            provenance.write_new_provenance(output, {"replacement":True})
        self.assertEqual(output.read_bytes(), existing)

    def test_provenance_main_uses_rollback_writer_on_sync_failure(self):
        library = self.root / "new-library.dylib"
        library.write_bytes(self.library)
        output = self.root / "failed-main.json"
        arguments = ["--library", str(library), "--source-root", str(self.root),
                     "--source-sha", REVISION, "--patch-version", "v19", "--output", str(output)]
        with patch.object(provenance.os, "fsync", side_effect=OSError("injected CLI sync failure")), \
             patch("sys.stderr", new=io.StringIO()), self.assertRaises(SystemExit) as failed:
            provenance.main(arguments)
        self.assertEqual(failed.exception.code, 2)
        self.assertFalse(output.exists())
        self.assertEqual(library.read_bytes(), self.library)

    def test_provenance_sync_failure_removes_only_its_new_output(self):
        output = self.root / "failed-write.json"
        preserved = self.root / "old.json"
        preserved.write_bytes(b"old artifact")
        with patch.object(provenance.os, "fsync", side_effect=OSError("injected sync failure")):
            with self.assertRaisesRegex(OSError, "injected sync failure"):
                provenance.write_new_provenance(output, self.value)
        self.assertFalse(output.exists())
        self.assertEqual(preserved.read_bytes(), b"old artifact")
        # The same new path is available again after rollback, without overwrite.
        provenance.write_new_provenance(output, self.value)
        self.assertEqual(json.loads(output.read_bytes()), self.value)

    def test_provenance_readback_failure_rolls_back_new_output(self):
        output = self.root / "failed-readback.json"
        with patch.object(Path, "read_bytes", return_value=b'{"truncated":true}'):
            with self.assertRaisesRegex(safe_macho.ValidationError, "readback mismatch"):
                provenance.write_new_provenance(output, self.value)
        self.assertFalse(output.exists())

    def test_provenance_failure_does_not_remove_replacement_identity(self):
        output = self.root / "replaced-output.json"
        replacement = self.root / "replacement.json"
        replacement.write_bytes(b"different file identity")
        def fail_after_replacement(path):
            replacement.replace(path)
            raise OSError("injected read after replacement")
        with patch.object(Path, "read_bytes", autospec=True, side_effect=fail_after_replacement):
            with self.assertRaisesRegex(OSError, "injected read after replacement"):
                provenance.write_new_provenance(output, self.value)
        self.assertEqual(output.read_bytes(), b"different file identity")

    def test_new_output_write_and_readback(self):
        output = self.root / "new.ipa"
        data = b"new synthetic package, not a real IPA"
        build_focus.write_new_package(output, data)
        self.assertEqual(output.read_bytes(), data)

    def test_new_output_and_input_collision(self):
        output = self.root / "new.ipa"
        self.assertEqual(provenance.new_output_path(output), output)
        with self.assertRaisesRegex(safe_macho.ValidationError, "input path"):
            provenance.new_output_path(output, [output])


class PackageTests(unittest.TestCase):
    setUp = ProvenanceTests.setUp

    def test_synthetic_package_resources_and_platform_are_verified(self):
        original, expected, manifest = patch_fixture()
        archive = zip_fixture(original)
        with patch.object(build_focus, "ORIGINAL_IPA_SHA256", focus_patches.sha256(archive)), \
             patch.object(build_focus, "load_patch_manifest", return_value=manifest):
            result = build_focus.assemble_package(archive, self.library, self.value, self.root)
        with zipfile.ZipFile(io.BytesIO(result)) as output:
            self.assertEqual(len(output.namelist()), 5)
            self.assertEqual(output.read(build_focus.LIBRARY_MEMBER), self.library)
            self.assertEqual(output.read("Payload/PPBrowser.app/resource.txt"), b"unchanged resource")
            self.assertEqual(plistlib.loads(output.read(build_focus.INFO_MEMBER))["MinimumOSVersion"], "14.0")
            self.assertEqual(safe_macho.parse_macho(output.read(build_focus.EXE_MEMBER)).minimum_ios,
                             safe_macho.version_number("14.0"))
            self.assertEqual(json.loads(output.read(build_focus.PROVENANCE_MEMBER))["source_sha"], REVISION)

    def test_rejects_wrong_original_and_preinjected_input(self):
        original, expected, manifest = patch_fixture()
        archive = zip_fixture(original)
        with self.assertRaisesRegex(safe_macho.ValidationError, "original IPA"):
            build_focus.assemble_package(archive, self.library, self.value, self.root)
        injected = zip_fixture(safe_macho.inject_load_dylib(original), [(build_focus.LIBRARY_MEMBER, self.library)])
        with patch.object(build_focus, "ORIGINAL_IPA_SHA256", focus_patches.sha256(injected)), \
             patch.object(build_focus, "load_patch_manifest", return_value=manifest):
            with self.assertRaisesRegex(safe_macho.ValidationError, "already-injected"):
                build_focus.assemble_package(injected, self.library, self.value, self.root)

    def test_rejects_duplicate_unsafe_and_tampered_resources(self):
        original, expected, manifest = patch_fixture()
        for resources in ([('../outside', b'x')], [('Payload/PPBrowser.app/resource.txt', b'duplicate')]):
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive = zip_fixture(original, resources)
            with self.subTest(resources=resources), zipfile.ZipFile(io.BytesIO(archive)) as z:
                with self.assertRaises(safe_macho.ValidationError): build_focus.validate_archive(z)
        archive = zip_fixture(original)
        with patch.object(build_focus, "ORIGINAL_IPA_SHA256", focus_patches.sha256(archive)), \
             patch.object(build_focus, "load_patch_manifest", return_value=manifest):
            result = build_focus.assemble_package(archive, self.library, self.value, self.root)
        altered = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(result)) as source, zipfile.ZipFile(altered, "w") as output:
            output.comment = source.comment
            packaged = json.loads(source.read(build_focus.PROVENANCE_MEMBER))
            for info in source.infolist():
                value = b"tampered" if info.filename.endswith("resource.txt") else source.read(info)
                # ZipFile.writestr mutates header_offset/CRC on the supplied
                # ZipInfo; never let the target rewrite the source index.
                output.writestr(copy(info), value)
        with self.assertRaisesRegex(safe_macho.ValidationError, "resource changed"):
            build_focus.verify_package(archive, altered.getvalue(), self.library, packaged, manifest)

    def test_cli_requires_explicit_inputs_and_new_output(self):
        with patch("sys.stderr", new=io.StringIO()), self.assertRaises(SystemExit) as result:
            build_focus.main([])
        self.assertEqual(result.exception.code, 2)
        old = self.root / "old.ipa"; old.write_bytes(b"preserve")
        args = ["--ipa", "missing.ipa", "--dylib", "missing.dylib", "--provenance", "missing.json",
                "--source-root", str(self.root), "--out", str(old)]
        with patch("sys.stderr", new=io.StringIO()), self.assertRaises(SystemExit) as result:
            build_focus.main(args)
        self.assertEqual(result.exception.code, 2)
        self.assertEqual(old.read_bytes(), b"preserve")


class LiveGitProvenanceTests(unittest.TestCase):
    def test_actual_checkout_is_commit_bound_or_rejects_dirty_sources(self):
        root = Path(__file__).resolve().parents[1]
        revision = provenance._git_read(root, "rev-parse", "--verify", "HEAD").decode("ascii").strip()
        status = provenance._git_read(root, "status", "--porcelain", "--untracked-files=all", "--", "src")
        source_changes = [line for line in status.decode("utf-8").splitlines()
                          if PurePosixPath(line[3:]).suffix in {".h", ".m"}]
        if source_changes:
            with self.assertRaisesRegex(safe_macho.ValidationError, "claimed Git commit"):
                provenance.source_file_manifest_for_revision(root, revision)
        else:
            self.assertEqual(provenance.source_file_manifest_for_revision(root, revision),
                             provenance.source_file_manifest(root))


def _default_ipa():
    """Original Focus IPA: shared ipa/ directory first, then the legacy checkout root."""
    checkout = Path(__file__).resolve().parents[2]
    for candidate in (checkout / "ipa" / "Focus_2.9.7.ipa", checkout / "Focus_2.9.7.ipa"):
        if candidate.is_file():
            return candidate
    return checkout / "ipa" / "Focus_2.9.7.ipa"


class ActualFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original_path = _default_ipa()
        cls.reference_path = cls.original_path.with_name("Focus_2.9.7_patched_v18.ipa")
        if not cls.original_path.is_file() or not cls.reference_path.is_file():
            raise unittest.SkipTest("reviewed local IPA fixtures are not present (not required on macOS CI)")

    def test_full_preimage_metadata_and_injection_recreate_v18_exactly(self):
        self.assertEqual(focus_patches.sha256(self.original_path.read_bytes()), focus_patches.ORIGINAL_IPA_SHA256)
        with zipfile.ZipFile(self.original_path) as source, zipfile.ZipFile(self.reference_path) as reference:
            original, expected = source.read(build_focus.EXE_MEMBER), reference.read(build_focus.EXE_MEMBER)
        business = focus_patches.apply_patch_manifest(original, focus_patches.load_patch_manifest())
        self.assertEqual(safe_macho.inject_load_dylib(business), expected)
        self.assertEqual(len(original), len(expected))
        self.assertEqual(sum(a != b for a, b in zip(original, expected)), 432)
        # Verifies read-only in-memory executable update, not a real new IPA build.
        raised = safe_macho.set_minimum_ios(expected, safe_macho.version_number("14.0"))
        self.assertEqual(safe_macho.parse_macho(raised).minimum_ios, safe_macho.version_number("14.0"))


if __name__ == "__main__":
    unittest.main()
