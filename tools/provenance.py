"""Bind a compiled FocusDM library to embedded build metadata and a source tree.

CI calls this *after* compiling. The builder repeats all checks: a CLI-supplied
revision alone is not evidence of which revision was compiled.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from tools.focus_patches import canonical_json, sha256
    from tools.safe_macho import LOAD_PATH, ValidationError, require, validate_dylib, version_string
else:
    from .focus_patches import canonical_json, sha256
    from .safe_macho import LOAD_PATH, ValidationError, require, validate_dylib, version_string

BUILD_METADATA_PREFIX = b"FOCUSDM_BUILD_METADATA:"
REVISION_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
PATCH_VERSION_PATTERN = re.compile(r"v([0-9]+)\Z")


def validate_build_identity(version, revision):
    match = PATCH_VERSION_PATTERN.fullmatch(str(version))
    require(match is not None and int(match[1]) >= 19, "only explicitly versioned v19+ libraries are accepted")
    require(REVISION_PATTERN.fullmatch(str(revision)) is not None, "source_sha must be a full lowercase Git SHA")


def embedded_build_metadata(library):
    """Read one unambiguous NUL-terminated JSON build marker in the library."""
    records = []
    start = 0
    while True:
        offset = library.find(BUILD_METADATA_PREFIX, start)
        if offset < 0:
            break
        value_start = offset + len(BUILD_METADATA_PREFIX)
        end = library.find(b"\0", value_start, min(len(library), value_start + 4096))
        require(end >= 0, "compiled build metadata is unterminated")
        try:
            record = json.loads(library[value_start:end].decode("utf-8"))
        except (ValueError, UnicodeError) as exc:
            raise ValidationError("compiled build metadata is not valid JSON") from exc
        require(isinstance(record, dict) and set(record) == {"schema_version", "patch_version", "source_sha"},
                "unsupported compiled build-metadata fields")
        require(record["schema_version"] == 1, "unsupported compiled build-metadata schema")
        validate_build_identity(record["patch_version"], record["source_sha"])
        records.append(record)
        start = end + 1
    require(bool(records), "library has no compiled FocusDM build metadata")
    require(all(record == records[0] for record in records), "library has conflicting compiled build identities")
    # Compilers may coalesce/repeat an identical constant; conflicting identities never pass.
    return records[0]


def source_file_manifest(root):
    root = Path(root).resolve(strict=True)
    source = root / "src"
    require(source.is_dir() and not source.is_symlink(), "source root needs a real src directory")
    files = sorted((p for p in source.iterdir() if p.is_file() and p.suffix in {".h", ".m"}),
                   key=lambda p: p.relative_to(root).as_posix())
    require(bool(files), "source root contains no Objective-C sources")
    require(not any(p.is_symlink() for p in files), "source manifest refuses symlinked sources")
    nested = [p for p in source.rglob("*") if p.is_file() and p.suffix in {".h", ".m"} and p.parent != source]
    require(not nested, "nested Objective-C sources need an explicit compile contract")
    return [{"path":p.relative_to(root).as_posix(), "sha256":sha256(p.read_bytes())} for p in files]


def _git_read(root, *arguments):
    """Read local Git objects only; no optional locks or lazy network fetches."""
    environment = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE"):
        environment.pop(key, None)
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_NO_LAZY_FETCH"] = "1"
    try:
        result = subprocess.run(["git", "-C", str(root), *arguments],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=environment, timeout=15, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValidationError("cannot read local Git provenance") from exc
    require(result.returncode == 0, "local Git provenance command failed: " +
            result.stderr.decode("utf-8", "replace").strip()[:500])
    require(len(result.stdout) <= 16 * 1024 * 1024, "Git provenance output exceeds its bound")
    return result.stdout


def source_file_manifest_for_revision(root, source_sha):
    """Bind exact current .h/.m bytes to the HEAD commit claimed by the library."""
    require(REVISION_PATTERN.fullmatch(str(source_sha)) is not None, "source_sha must be a full lowercase Git SHA")
    root = Path(root).resolve(strict=True)
    repository = Path(_git_read(root, "rev-parse", "--show-toplevel").decode("utf-8").strip()).resolve(strict=True)
    require(repository == root, "source root must be the exact Git repository root")
    require(_git_read(root, "rev-parse", "--verify", "HEAD").decode("ascii").strip() == source_sha,
            "source_sha does not match the checked-out HEAD")
    tree = _git_read(root, "ls-tree", "-r", "-z", source_sha, "--", "src")
    committed = []
    for record in tree.split(b"\0"):
        if not record:
            continue
        try:
            identity, raw_path = record.split(b"\t", 1)
            mode, kind, object_id = identity.decode("ascii").split(" ")
            name = raw_path.decode("utf-8")
        except (ValueError, UnicodeError) as exc:
            raise ValidationError("invalid Git source-tree record") from exc
        path = PurePosixPath(name)
        require(kind != "commit", "source tree cannot contain submodules")
        if path.suffix not in {".h", ".m"}:
            continue
        require(mode in {"100644", "100755"} and kind == "blob",
                "compiled sources must be ordinary tracked blobs (not symlinks)")
        require(path.parts[0:1] == ("src",) and len(path.parts) == 2 and "\\" not in name,
                "nested Objective-C sources need an explicit compile contract")
        require(re.fullmatch(r"[0-9a-f]{40}", object_id) is not None, "invalid Git blob identity")
        contents = _git_read(root, "cat-file", "blob", object_id)
        committed.append({"path":name, "sha256":sha256(contents)})
    committed.sort(key=lambda entry:entry["path"])
    _validate_file_manifest(committed)
    require(source_file_manifest(root) == committed,
            "current source tree differs from the claimed Git commit (dirty/missing/untracked sources)")
    require(_git_read(root, "rev-parse", "--verify", "HEAD").decode("ascii").strip() == source_sha,
            "checked-out HEAD changed while validating sources")
    return committed


def _validate_file_manifest(files):
    require(isinstance(files, list) and bool(files), "source_files must be a nonempty list")
    names = []
    for entry in files:
        require(isinstance(entry, dict) and set(entry) == {"path", "sha256"}, "invalid source manifest entry")
        path = PurePosixPath(entry["path"])
        require(path.parts[0:1] == ("src",) and len(path.parts) == 2 and
                path.suffix in {".h", ".m"} and ".." not in path.parts and
                "\\" not in entry["path"], "invalid source manifest path")
        require(re.fullmatch(r"[0-9a-f]{64}", str(entry["sha256"])) is not None, "invalid source SHA-256")
        names.append(entry["path"])
    require(names == sorted(set(names)), "source manifest must be sorted and unique")


def create_provenance(library, source_root, patch_version, source_sha):
    validate_build_identity(patch_version, source_sha)
    image = validate_dylib(library)
    embedded = embedded_build_metadata(library)
    require(embedded["patch_version"] == patch_version and embedded["source_sha"] == source_sha,
            "CLI build identity does not match the compiled library")
    files = source_file_manifest_for_revision(source_root, source_sha)
    return {
        "schema_version":1,
        "patch_version":patch_version,
        "source_sha":source_sha,
        "library_sha256":sha256(library),
        "library_size":len(library),
        "install_name":LOAD_PATH,
        "minimum_ios":version_string(image.minimum_ios),
        "embedded_build_metadata":embedded,
        "source_files":files,
        "source_manifest_sha256":sha256(canonical_json(files)),
    }


def validate_provenance(value, library, source_root):
    require(isinstance(value, dict) and value.get("schema_version") == 1, "unsupported provenance schema")
    validate_build_identity(value.get("patch_version"), value.get("source_sha"))
    require(value.get("library_sha256") == sha256(library) and value.get("library_size") == len(library),
            "library hash/size does not match provenance")
    image = validate_dylib(library)
    require(value.get("install_name") == LOAD_PATH and value.get("minimum_ios") == version_string(image.minimum_ios),
            "library identity/minimum iOS does not match provenance")
    embedded = embedded_build_metadata(library)
    require(value.get("embedded_build_metadata") == embedded and
            value["patch_version"] == embedded["patch_version"] and value["source_sha"] == embedded["source_sha"],
            "provenance identity does not match compiled metadata")
    files = value.get("source_files")
    _validate_file_manifest(files)
    require(value.get("source_manifest_sha256") == sha256(canonical_json(files)), "source manifest hash mismatch")
    require(source_file_manifest_for_revision(source_root, value["source_sha"]) == files,
            "current source tree differs from compiled-source manifest")
    return image


def new_output_path(output, inputs=()):
    requested = Path(output)
    require(not requested.exists() and not requested.is_symlink(), "output already exists; overwrite is forbidden")
    path = requested.resolve()
    require(path.parent.is_dir(), "output directory must already exist")
    require(not path.exists() and not path.is_symlink(), "output already exists; overwrite is forbidden")
    for item in inputs:
        require(path != Path(item).resolve(), "output must not be an input path")
    return path


def write_new_provenance(path, value):
    """Create one new JSON artifact; failed writes remove only our own file."""
    payload = canonical_json(value) + b"\n"
    created_identity = None
    try:
        with path.open("xb") as handle:
            status = os.fstat(handle.fileno())
            created_identity = (status.st_dev, status.st_ino)
            require(handle.write(payload) == len(payload), "incomplete provenance write")
            handle.flush()
            os.fsync(handle.fileno())
        readback = path.read_bytes()
        require(readback == payload and json.loads(readback) == value,
                "provenance write/readback mismatch")
    except BaseException:
        if created_identity is not None:
            try:
                # Do not follow a replacement symlink or remove a different file
                # installed at the output path after our exclusive creation.
                status = path.lstat()
                if (status.st_dev, status.st_ino) == created_identity:
                    path.unlink()
            except OSError:
                pass
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--patch-version", required=True)
    parser.add_argument("--output", required=True)
    options = parser.parse_args(argv)
    try:
        output = new_output_path(options.output, [options.library])
        library = Path(options.library).read_bytes()
        value = create_provenance(library, options.source_root, options.patch_version, options.source_sha)
        validate_provenance(value, library, options.source_root)
        write_new_provenance(output, value)
        print(f"Provenance: {output} ({value['patch_version']}, {value['source_sha']})")
        return 0
    except (OSError, ValueError, TypeError, KeyError) as exc:
        parser.exit(2, f"Provenance rejected: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
