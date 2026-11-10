"""Architecture guards; completion ordering and restoration run in UIKit fixtures."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PageNavigationContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = (ROOT / "src/FocusDM.m").read_text(encoding="utf-8")
        cls.shared = (ROOT / "src/FDMPageNavigation.m").read_text(encoding="utf-8")
        cls.downloads = (ROOT / "src/FDMDownloadsViewController.m").read_text(encoding="utf-8")

    def test_all_toolbar_owned_actions_wait_for_host_cleanup(self):
        block = self.host.split("static void FDMPreferenceSelect(", 1)[1].split("static void FDMPreferenceUpdate(", 1)[0]
        self.assertEqual(block.count("FDMClosePreferenceThenPerform(self,"), 3)
        self.assertNotIn("hideUserPreferenceView", block)
        self.assertIn("@selector(removeFromSuperview)", self.shared)
        self.assertIn("@selector(dismissViewControllerAnimated:completion:)", self.shared)
        self.assertIn("if (completion) completion();", self.shared)
        self.assertIn("!self.panelRemoved || !self.popupDismissed", self.shared)
        self.assertNotIn("dispatch_after", self.shared)

    def test_page_surface_is_prepared_before_native_push(self):
        show = self.shared.split("void FDMShowOwnedPage(", 1)[1].split("@interface FDMPreferenceClosing", 1)[0]
        self.assertLess(show.index("FDMPrepareOwnedPage(page);"), show.index("pushViewController:page animated:YES"))
        self.assertIn("page.edgesForExtendedLayout = UIRectEdgeNone", self.shared)
        self.assertIn("navigation.view.clipsToBounds = YES", self.shared)
        self.assertIn("objc_getAssociatedObject(page, &FDMNavigationAppearanceKey)", self.shared)
        self.assertNotIn("addSubview:", self.shared)

    def test_state_restore_uses_final_controller_and_cancel_context(self):
        will = self.host.split("static void FDMNavigationWillShow(", 1)[1].split("static void FDMNavigationDidShow(", 1)[0]
        did = self.host.split("static void FDMNavigationDidShow(", 1)[1].split("static void FDMShowDownloadPill(", 1)[0]
        self.assertIn("if (!context.isCancelled) return;", will)
        self.assertIn("current.topViewController", will)
        self.assertLess(did.index("FDMFinishOwnedNavigationTransition"), did.index("FDMOriginalNavigationDidShow"))
        self.assertNotIn("_navWasHidden", self.downloads)
        self.assertNotIn("_navSaved", self.downloads)

    def test_cached_appearance_is_assigned_only_when_first_created(self):
        prepare = self.shared.split("static void FDMPrepareNavigationPage(", 1)[1].split("void FDMPrepareOwnedPage(", 1)[0]
        creation_start = prepare.index("if (!appearance) {")
        creation_end = prepare.index("\n    }", creation_start)
        for name in ("standardAppearance", "scrollEdgeAppearance", "compactAppearance", "compactScrollEdgeAppearance"):
            assignment = f"page.navigationItem.{name} = appearance"
            self.assertEqual(prepare.count(assignment), 1)
            self.assertLess(creation_start, prepare.index(assignment))
            self.assertLess(prepare.index(assignment), creation_end)

    def test_native_navigation_and_gesture_owners_are_preserved(self):
        self.assertNotIn("setDelegate:", self.shared)
        self.assertNotIn(".delegate =", self.shared)
        self.assertNotIn("interactivePopGestureRecognizer", self.shared)
        self.assertIn("FDMOriginalNavigationWillShow", self.host)
        self.assertIn("FDMOriginalNavigationDidShow", self.host)

    def test_host_surface_is_not_restored_inside_an_owned_navigation_stack(self):
        finish = self.shared.split("void FDMFinishOwnedNavigationTransition(", 1)[1].split("void FDMShowOwnedPage(", 1)[0]
        self.assertIn("FDMIsOwnedNavigationPage(navigation, page)", finish)
        self.assertIn("if (candidate == page) return ownedAncestor", self.shared)
        self.assertIn('isEqual:@"FDMURLInputController"', self.shared)
        form = self.downloads.split("@implementation FDMURLInputController", 1)[1].split("@implementation FDMDownloadsViewController", 1)[0]
        self.assertIn("FDMPrepareOwnedPage(self)", form)

    def test_pending_toolbar_action_does_not_capture_the_browser(self):
        block = self.host.split("static void FDMPreferenceSelect(", 1)[1].split("static void FDMPreferenceUpdate(", 1)[0]
        self.assertEqual(block.count("^(UIViewController *host)"), 3)
        self.assertNotIn("^{", block)
        self.assertIn("@property (nonatomic, weak) UIViewController *host", self.shared)
        self.assertIn("if (!host) return;", self.shared)

    def test_native_callback_and_nested_navigation_fixture_is_wired(self):
        app = (ROOT / "tests/icons_app_main.m").read_text(encoding="utf-8")
        runner = (ROOT / "tests/run_icons_simulator.py").read_text(encoding="utf-8")
        fixture = (ROOT / "tests/page_navigation_regression.m").read_text(encoding="utf-8")
        self.assertIn("FDMRunPageNavigationRegressionTests(^(NSException *exception)", app)
        self.assertIn("FDMFinishSimulatorRegression(exception);", app)
        self.assertIn("tests/page_navigation_regression.m", runner)
        for marker in ("popup-first order", "panel-first order", "nested URL form", "system child", "cancelled swipe", "successful pop"):
            self.assertIn(marker, fixture)

    def test_callback_fixture_yields_main_queue_instead_of_pumping_it_recursively(self):
        fixture = (ROOT / "tests/page_navigation_regression.m").read_text(encoding="utf-8")
        self.assertIn("FDMRunNavigationPhases(phases, index + 1, completion)", fixture)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", fixture)
        self.assertNotIn("CFRunLoopRunInMode", fixture)
        self.assertNotIn("FDMDrainNavigationCallbacks", fixture)
        self.assertIn("completion(exception);", fixture)

    def test_site_pages_share_navigation_without_backup_changes(self):
        sites = (ROOT / "src/FDMNativePages.m").read_text(encoding="utf-8").split("#pragma mark - backup", 1)[0]
        navigation = (ROOT / "src/FDMNavigation.m").read_text(encoding="utf-8")
        self.assertIn("FDMShowOwnedPage(self, page)", sites)
        self.assertIn("FDMShowOwnedPage(host, page)", navigation)
        self.assertIn("FDMPrepareOwnedPage(self)", sites)


if __name__ == "__main__":
    unittest.main()
