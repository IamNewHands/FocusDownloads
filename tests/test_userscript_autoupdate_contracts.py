"""Architecture & contract regressions for the Focus UserScript auto-update patch.

Validates that user scripts auto-update on a daily throttle,
integrates natively into Focus UserScript controller UI, and avoids hard symbols.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UserScriptAutoUpdateContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (ROOT / "src/FDMUserScriptUpdater.h").read_text(encoding="utf-8")
        cls.source = (ROOT / "src/FDMUserScriptUpdater.m").read_text(encoding="utf-8")
        cls.focusdm = (ROOT / "src/FocusDM.m").read_text(encoding="utf-8")

    def test_userscript_updater_files_exist_and_non_empty(self):
        self.assertGreater(len(self.header), 100)
        self.assertGreater(len(self.source), 500)

    def test_userscript_updater_public_contract(self):
        # Constants
        for const in (
            "FDMUserScriptAutoUpdateEnabledKey",
            "FDMUserScriptLastSuccessDateKey",
            "FDMUserScriptLastAttemptDateKey",
            "FDMUserScriptDidUpdateNotification",
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
        self.assertIn("_fdmUserScriptUpdating", self.source)
        # Must have backoff interval on failure to prevent network spam
        self.assertIn("FDMUserScriptFailureBackoffInterval", self.source)
        self.assertIn("900.0", self.source)

    def test_host_symbol_decoupling(self):
        # Host classes must be looked up dynamically to prevent dyld load errors
        for host_class in (
            "UserScriptUpdateManager",
            "UserScriptController",
        ):
            self.assertIn(f'NSClassFromString(@"{host_class}")', self.source)
            self.assertNotIn(f"@interface {host_class}", self.header)
            self.assertNotIn(f"@interface {host_class}", self.source)

    def test_userscript_update_workflow_integrity(self):
        # Manager resolution and execution
        self.assertIn('NSSelectorFromString(@"shareInstance")', self.source)
        self.assertIn('NSSelectorFromString(@"updateUserScripts")', self.source)
        # Notifications
        self.assertIn('FDMUserScriptDidUpdateNotification', self.source)

    def test_ui_header_injection_and_hooks(self):
        # Table header view injection
        self.assertIn("tableView.tableHeaderView", self.source)
        self.assertIn("FDMUserScriptHeaderView", self.source)
        self.assertIn("FDMUserScriptHeaderTag", self.source)
        self.assertIn("FDMUserScriptSwitchTag", self.source)
        self.assertIn("FDMUserScriptDetailTag", self.source)
        # Visual style coordination: white card, green switch, left icon
        self.assertIn("sw.onTintColor", self.source)
        self.assertIn("arrow.triangle.2.circlepath", self.source)
        self.assertIn("whiteColor", self.source)
        # Switch alignment with lower cells
        self.assertIn("switchView", self.source)
        # Swizzles viewWillAppear:, reloadData and _updateAllUserscripts
        self.assertIn("viewWillAppear:", self.source)
        self.assertIn("reloadData", self.source)
        self.assertIn('_updateAllUserscripts', self.source)

    def test_host_integration_in_focusdm(self):
        self.assertIn('#import "FDMUserScriptUpdater.h"', self.focusdm)
        self.assertIn("[FDMUserScriptUpdater installHooks];", self.focusdm)
        self.assertIn("[FDMUserScriptUpdater checkAndTriggerDailyUpdateIfNeeded];", self.focusdm)


if __name__ == "__main__":
    unittest.main()
