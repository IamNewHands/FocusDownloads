"""Architecture guards, not iOS behavior evidence.

Native fixtures execute FDMEngine, strict DTOs, real SQLite and WebKit separately.
These tests only keep known-invalid integration paths from returning.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(name):
    return (ROOT / 'src' / name).read_text(encoding='utf-8')

class ArchitectureGuards(unittest.TestCase):
    def test_original_navigation_download_never_reissues_post(self):
        text = source('FDMNavigation.m')
        self.assertIn('WKNavigationResponsePolicyDownload', text)
        self.assertIn('didBecomeDownload:', text)
        self.assertNotIn('startDownloadUsingRequest:', text)
        self.assertNotIn('takeIntentMatchingURL:', text)

    def test_capture_has_one_navigation_owner(self):
        host = source('FocusDM.m')
        nav = source('FDMNavigation.m')
        self.assertIn('FDMInstallNavigationHooks()', host)
        self.assertNotIn('FDMNavAction', host)
        self.assertNotIn('FDMOriginalIMPFor', host)
        self.assertIn('Class aggregate = NSClassFromString(@"WebViewNavDelegate")', nav)

    def test_engine_has_no_ui_or_second_memory_transport(self):
        text = source('FDMEngine.m')
        self.assertNotIn('#import <UIKit/', text)
        self.assertNotIn('FDMCredentialedTransport', text)
        self.assertNotIn('NSMutableData *_body', source('FDMIntent.m'))
        self.assertIn('bindWebKitKey:', text)

    def test_current_webkit_redirect_selector_is_public(self):
        text = source('FDMWebKitDownloads.m')
        self.assertIn('decisionHandler:', text)
        self.assertIn('resumeDownloadFromResumeData:', text)

    def test_new_resume_is_device_local_not_public_plaintext(self):
        engine = source('FDMEngine.m')
        vault = source('FDMVault.m')
        self.assertIn('FDMVaultPut', engine)
        self.assertIn('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly', vault)
        self.assertIn('kSecAttrSynchronizable', vault)
        self.assertIn('resumeVaultID', engine)

    def test_anonymous_background_has_no_ambient_cookies_or_credentials(self):
        text = source('FDMEngine.m')
        for fragment in ['HTTPShouldSetCookies = NO', 'HTTPCookieStorage = nil', 'URLCredentialStorage = nil']:
            self.assertIn(fragment, text)

    def test_strict_configuration_parser_keeps_key_and_depth_checks(self):
        text = source('FDMJSON.m')
        self.assertIn('[keys containsObject:key]', text)
        self.assertIn('scanner->depth >= scanner->maxDepth', text)
        self.assertNotIn('[NSJSONSerialization JSONObjectWithData:', text)
        self.assertIn('CFBooleanGetTypeID', text)

    def test_backup_has_real_repository_not_html_or_cache_only_commit(self):
        text = source('FDMBackupCoordinator.m')
        self.assertIn('applyPlan:', text)
        self.assertNotIn('parseBookMarksFromHtml:', text)
        self.assertNotIn('@interface FDMBookmarkProvider', text)
        self.assertIn('beforeSHA256', text)

    def test_backup_scripts_are_opt_in(self):
        self.assertIn('return ![category isEqual:FDMBackupCategoryScripts]', source('FDMBackup.m'))

    def test_stable_icon_owner_is_not_imported_by_download_ui(self):
        self.assertNotIn('#import "FDMIcons.h"', source('FDMDownloadsViewController.m'))

    def test_ci_compiles_all_sources_with_actual_sdk(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        self.assertIn('src/*.m', workflow)
        self.assertIn('-framework WebKit', workflow)
        self.assertIn('-framework Security', workflow)
        self.assertIn('tests/backup_regression.m', workflow)

if __name__ == '__main__':
    unittest.main()
