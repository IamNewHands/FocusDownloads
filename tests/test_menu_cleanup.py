"""Source-contract checks for the retired download-menu diagnostic entry.

These guards do not execute UIKit. Existing native cache regression remains the
runtime verification path; this cleanup must not change that cache owner.
"""
from pathlib import Path
import unittest


class DownloadMenuCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.source = (root / "src" / "FDMDownloadsViewController.m").read_text(encoding="utf-8")
        cls.menu = cls.source.split("- (void)showMore {", 1)[1].split("- (NSDictionary *)rowAt:", 1)[0]

    def test_diagnostic_is_not_a_download_menu_action(self):
        self.assertNotIn("图标缓存诊断", self.menu)
        self.assertNotIn("FDMCreateIconDiagnosticsViewController", self.source)

    def test_help_action_is_preserved(self):
        self.assertIn("保存位置与使用说明", self.menu)
        self.assertIn("UIActivityViewController", self.source)
        self.assertIn("QLPreviewController", self.source)

    def test_download_page_no_longer_imports_the_icon_owner(self):
        self.assertNotIn('#import "FDMIcons.h"', self.source)


if __name__ == "__main__":
    unittest.main()
