"""Architecture & contract regressions for the Focus AdBlock rules auto-update patch.

Validates that ad-blocking filter rules auto-update on a daily throttle,
integrates natively into Focus host settings, and avoids hard symbols.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AdBlockAutoUpdateContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (ROOT / "src/FDMAdBlockUpdater.h").read_text(encoding="utf-8")
        cls.source = (ROOT / "src/FDMAdBlockUpdater.m").read_text(encoding="utf-8")
        cls.focusdm = (ROOT / "src/FocusDM.m").read_text(encoding="utf-8")

    def test_adblock_updater_files_exist_and_non_empty(self):
        self.assertGreater(len(self.header), 100)
        self.assertGreater(len(self.source), 500)

    def test_adblock_updater_public_contract(self):
        # Constants
        for const in (
            "FDMAdBlockAutoUpdateEnabledKey",
            "FDMAdBlockLastSuccessDateKey",
            "FDMAdBlockLastAttemptDateKey",
            "FDMAdBlockDidUpdateNotification",
        ):
            self.assertIn(const, self.header)
            self.assertIn(const, self.source)

        # Public methods
        for method in (
            "+ (BOOL)isAutoUpdateEnabled;",
            "+ (void)setAutoUpdateEnabled:(BOOL)enabled;",
            "+ (BOOL)isUpdating;",
            "+ (NSDate * _Nullable)lastSuccessDate;",
            "+ (NSString * _Nullable)lastSuccessDateString;",
            "+ (BOOL)shouldPerformDailyUpdate;",
            "+ (void)checkAndTriggerDailyUpdateIfNeeded;",
            "+ (void)performUpdateWithCompletion:",
            "+ (void)recordUpdateSuccessNow;",
            "+ (void)installHooks;",
        ):
            self.assertIn(method, self.header)

    def test_daily_execution_gating_logic(self):
        # Must verify throttle once per calendar day
        self.assertIn("isDateInToday:lastSuccess", self.source)
        # Must check if feature is enabled
        self.assertIn("[self isAutoUpdateEnabled]", self.source)
        # Must prevent concurrent duplicate execution
        self.assertIn("_fdmAdBlockUpdating", self.source)
        # Must have backoff interval on failure to prevent network spam
        self.assertIn("FDMAdBlockFailureBackoffInterval", self.source)
        self.assertIn("900.0", self.source)

    def test_host_symbol_decoupling(self):
        # Host classes must be looked up dynamically to prevent dyld load errors
        for host_class in (
            "AdBlockManager",
            "AdBlockModel",
            "DatabaseUnit",
            "DatabaseUtil",
            "SettingSwitchAndTextView",
            "AdBlockHomeController",
            "AdBlockViewController",
            "PreferenceManager",
        ):
            self.assertIn(f'NSClassFromString(@"{host_class}")', self.source)
            self.assertNotIn(f"@interface {host_class}", self.header)
            self.assertNotIn(f"@interface {host_class}", self.source)

    def test_adblock_update_workflow_integrity(self):
        # Database query
        self.assertIn('NSSelectorFromString(@"queryAllAdblocks")', self.source)
        self.assertIn('NSSelectorFromString(@"setCompleteBlock:")', self.source)
        # Built-in EasyList China URL
        self.assertIn('NSSelectorFromString(@"easylistChinaUrl")', self.source)
        # Remove and re-add rules
        self.assertIn('NSSelectorFromString(@"removeRulesForUrl:")', self.source)
        self.assertIn('NSSelectorFromString(@"addRulesFromUrl:completion:")', self.source)
        # Database timestamp update
        self.assertIn('NSSelectorFromString(@"updateAdblockWithId:")', self.source)
        # Notifications to reload WebViews and UI
        self.assertIn('kReloadAllWebViewNotification', self.source)
        self.assertIn('FDMAdBlockDidUpdateNotification', self.source)
        # Dispatch group for concurrent rule downloads
        self.assertIn("dispatch_group_create()", self.source)
        self.assertIn("dispatch_group_enter(group)", self.source)
        self.assertIn("dispatch_group_leave(group)", self.source)
        self.assertIn("dispatch_group_notify(group", self.source)

    def test_host_integration_in_focusdm(self):
        self.assertIn('#import "FDMAdBlockUpdater.h"', self.focusdm)
        self.assertIn("[FDMAdBlockUpdater installHooks];", self.focusdm)
        self.assertIn("[FDMAdBlockUpdater checkAndTriggerDailyUpdateIfNeeded];", self.focusdm)
        # Hooked on applicationDidBecomeActive:
        self.assertIn('NSSelectorFromString(@"applicationDidBecomeActive:")', self.focusdm)
        self.assertIn("FDMDidBecomeActive", self.focusdm)
        # Scheduled on cold launch in FDMDidFinishLaunch
        self.assertIn("dispatch_after", self.focusdm)

    def test_settings_switch_presentation(self):
        # View tag
        self.assertIn("FDMAdBlockSwitchTag", self.source)
        self.assertIn("0x46444D41", self.source)
        # Hooked in AdBlockHomeController updateWithModel and applyTheme
        self.assertIn("FDMAdBlockHomeUpdateWithModel", self.source)
        self.assertIn("FDMAdBlockHomeApplyTheme", self.source)
        # Row configuration
        self.assertIn("自动更新规则", self.source)
        self.assertIn("每天首次进入浏览器时自动更新", self.source)
        self.assertIn('NSSelectorFromString(@"setDidSwithAction:")', self.source)
        # Hooked in AdBlockViewController to reload when updated
        self.assertIn("FDMAdBlockViewControllerViewDidLoad", self.source)
        self.assertIn('NSSelectorFromString(@"reloadData")', self.source)
        self.assertIn("FDMAdBlockViewUpdateItems", self.source)


if __name__ == "__main__":
    unittest.main()
