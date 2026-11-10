"""Source guards for native-host export regressions; executable coverage is in backup_regression.m."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackupExportContracts(unittest.TestCase):
    def test_bookmark_export_and_replace_preserve_native_root(self):
        text = (ROOT / "src/FDMBackupRepositoryBookmarks.m").read_text(encoding="utf-8")
        self.assertIn('return [identifier isEqual:@"root"];', text)
        self.assertIn('if (FDMBackupBookmarkIsRoot(item[@"id"])) continue;', text)
        self.assertIn('!FDMBackupBookmarkIsRoot(identifier) && ![imported containsObject:identifier]', text)
        self.assertIn('!FDMBackupBookmarkIsRoot(identifier) && ![kept containsObject:identifier]', text)

    def test_empty_shortcut_address_is_only_valid_for_native_bookmark_action(self):
        text = (ROOT / "src/FDMBackupRepositoryBookmarks.m").read_text(encoding="utf-8")
        self.assertIn('row[@"parentID"] ||', text)
        self.assertIn('url && ![url isKindOfClass:NSString.class]', text)
        self.assertIn('![row[@"fileType"] isEqual:@1]', text)
        self.assertIn('if (!url.length && ![row[@"type"] isEqual:@1])', text)

    def test_font_index_matches_host_picker_not_point_size(self):
        text = (ROOT / "src/FDMBackupRepositoryPreferences.m").read_text(encoding="utf-8")
        self.assertIn('@"fontSize": @[@0, @9]', text)
        self.assertNotIn('@"fontSize": @[@8, @72]', text)

    def test_export_failure_always_has_category_and_stage_without_exception_reason(self):
        text = (ROOT / "src/FDMBackupCoordinator.m").read_text(encoding="utf-8")
        export = text.split("- (NSData *)exportCategories:", 1)[1].split("- (FDMBackupContainer *)", 1)[0]
        self.assertIn('FDMBackupExportFailure(category, @"读取"', export)
        self.assertIn('FDMBackupExportFailure(category, @"校验"', export)
        self.assertNotIn("exception.reason", export)
        self.assertIn("*error = failure ?: accessFailure ?: FDMBackupFailure", export)

    def test_export_does_not_write_back_over_its_callback_error(self):
        text = (ROOT / "src/FDMBackupCoordinator.m").read_text(encoding="utf-8")
        export = text.split("- (NSData *)exportCategories:", 1)[1].split("- (FDMBackupContainer *)", 1)[0]
        self.assertIn("NSError *accessFailure = nil;", export)
        self.assertIn("error:&accessFailure];", export)
        self.assertNotIn("error:&failure];", export)
        fixture = (ROOT / "tests/backup_regression.m").read_text(encoding="utf-8")
        self.assertIn("for (NSNumber *sqlStorage in @[@NO, @YES])", fixture)

    def test_native_tests_cover_each_default_category_and_combined_export(self):
        text = (ROOT / "tests/backup_regression.m").read_text(encoding="utf-8")
        for fragment in (
            'INSERT INTO t_bookmark(bookmarkId,parentId,title)',
            'all default categories export together',
            'exports independently',
            'replace preserves sentinel null columns',
            'ordinary shortcuts still require URLs',
            'invalid font indices refused',
            'host exception becomes bounded validation diagnostic',
            'FDMBackupBeginCase(@"HostDefaultExportShapes"); FDMTestHostDefaultExportShapes();',
            'FDMBackupBeginCase(@"ExportFailureDiagnostics"); FDMTestExportFailureDiagnostics();',
        ):
            self.assertIn(fragment, text)


if __name__ == "__main__":
    unittest.main()
