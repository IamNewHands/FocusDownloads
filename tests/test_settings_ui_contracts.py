"""Source guards only; settings/download UIKit behavior runs in the CI fixture."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SettingsUIContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = (ROOT / "src/FocusDM.m").read_text(encoding="utf-8")
        cls.downloads = (ROOT / "src/FDMDownloadsViewController.m").read_text(encoding="utf-8")
        cls.page_navigation = (ROOT / "src/FDMPageNavigation.m").read_text(encoding="utf-8")

    def test_owned_type_cannot_render_vip_or_recommendation_cells(self):
        match = re.search(r"FDMSettingsRowType = (0x[0-9a-f]+|\d+);", self.host)
        self.assertIsNotNone(match)
        self.assertNotIn(int(match[1], 0), (0, 17))
        self.assertIn('FDMSetSettingsValue(row, @"type", @(FDMSettingsRowType))', self.host)
        self.assertNotIn('@[@"imageName", @"imageBackgroundColor", @"type"]', self.host)

    def test_ordinary_template_does_not_require_a_navigation_link(self):
        block = self.host.split("id template = nil;", 1)[1].split("BOOL changed = NO;", 1)[0]
        self.assertIn("type > 0 && type != 17", block)
        self.assertNotIn('FDMString(FDMValue(candidate, @"link")).length', block)

    def test_settings_insert_in_one_batch_and_only_reload_when_changed(self):
        appear = self.host.split("static void FDMSettingsAppear(", 1)[1].split("static void FDMSettingsUpdate(", 1)[0]
        self.assertEqual(appear.count("FDMEnsureSettingsRows(self);"), 1)
        self.assertIn("if (!existing[link]) existing[link] = row;", self.host)
        self.assertIn("if (changed && [table isKindOfClass:UITableView.class]) [table reloadData];", self.host)
        self.assertIn('(IMP)FDMSettingsUpdate, &FDMOriginalSettingsUpdate', self.host)

    def test_navigation_appearance_belongs_to_the_download_item(self):
        self.assertIn("FDMPrepareOwnedPage(self);", self.downloads)
        self.assertIn("[appearance configureWithOpaqueBackground]", self.page_navigation)
        for name in ("standardAppearance", "scrollEdgeAppearance", "compactAppearance", "compactScrollEdgeAppearance"):
            self.assertIn(f"page.navigationItem.{name} = appearance", self.page_navigation)
        self.assertNotIn("navigation.navigationBar.standardAppearance =", self.downloads)
        show = self.page_navigation.split("void FDMShowOwnedPage(", 1)[1].split("@interface FDMPreferenceClosing", 1)[0]
        self.assertLess(show.index("FDMApplyOwnedNavigationState(navigation, page, NO);"),
                        show.index("pushViewController:page animated:YES"))

    def test_snapshots_wait_for_completed_appearance(self):
        page = self.downloads.split("@implementation FDMDownloadsViewController", 1)[1]
        before_appeared = page.split("- (void)viewDidAppear:", 1)[0]
        self.assertNotIn("[self refresh];", before_appeared)
        self.assertIn("CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode", self.downloads)
        self.assertIn("self->_refreshGeneration != generation", self.downloads)
        self.assertIn("if (!self.isViewLoaded || _refreshing) return;", self.downloads)

    def test_scrolling_and_departure_suspend_refresh_work(self):
        self.assertIn("if (!_refreshReady || _refreshScheduled || _scrolling) return;", self.downloads)
        disappear = self.downloads.split("- (void)viewWillDisappear:", 1)[1].split("- (void)viewDidDisappear:", 1)[0]
        self.assertIn("[self stopObserving];", disappear)
        self.assertIn("forMode:NSDefaultRunLoopMode", self.downloads)
        self.assertIn("scrollViewDidEndDecelerating:", self.downloads)

    def test_unwanted_settings_menus_hidden_and_deleted(self):
        # Must define filter function
        self.assertIn("FDMShouldHideSettingsRow", self.host)
        # Must filter type 17 (RecommendCell)
        self.assertIn("type == 17", self.host)
        # Must filter by specific icon assets
        for icon in ("setting_lock", "setting_info", "setting_question", "setting_star", "setting_share", "addons_logo", "qingyue_logo"):
            self.assertIn(icon, self.host)
        # Must filter by bundle localization keys
        for key in ("setting.privacyProtocol", "setting.aboutUs", "setting.guideline", "setting.rate", "setting.shareToFirend", "setting.qingyue.title", "setting.addons.detail"):
            self.assertIn(key, self.host)
        # Must filter by title strings
        for title in ("隐私协议", "关于我们", "使用帮助", "评价应用", "分享给朋友", "Addons", "轻阅"):
            self.assertIn(title, self.host)
        # Must strip empty sections and synchronize sectionHeaderModel
        self.assertIn("finalSections", self.host)
        self.assertIn("finalHeaders", self.host)

    def test_native_settings_and_download_fixtures_are_executed(self):
        app = (ROOT / "tests/icons_app_main.m").read_text(encoding="utf-8")
        runner = (ROOT / "tests/run_icons_simulator.py").read_text(encoding="utf-8")
        for name in ("Settings", "DownloadUI"):
            self.assertIn(f"FDMRun{name}RegressionTests();", app)
        self.assertIn("tests/settings_regression.m", runner)
        self.assertIn("tests/download_ui_regression.m", runner)
        self.assertIn('(root / "src").glob("*.m")', runner)
        self.assertIn('"-lsqlite3"', runner)


if __name__ == "__main__":
    unittest.main()
