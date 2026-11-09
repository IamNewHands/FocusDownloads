"""Source-contract guards for the v20 feature set.

These are static checks only: they cannot execute Objective-C. They catch the
class of mistake that a compiler would otherwise catch on the macOS runner, so
a push does not waste a full CI round on a trivial symbol error.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def read(name):
    return (SRC / name).read_text(encoding="utf-8")


class NewModuleContractTests(unittest.TestCase):
    def test_every_new_source_file_exists_and_is_compiled(self):
        workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
        for name in ["FDMJSON.m", "FDMPolicy.m", "FDMIntent.m", "FDMBackup.m",
                     "FDMBackupCoordinator.m", "FDMNativePages.m", "FDMWebKitDownloads.m"]:
            self.assertTrue((SRC / name).is_file(), f"{name} must exist")
        # The dylib build compiles src/*.m, so a new file is picked up automatically.
        self.assertIn("src/*.m", workflow)

    def test_foundation_regression_compiles_the_new_owners(self):
        workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
        for name in ["src/FDMJSON.m", "src/FDMPolicy.m", "src/FDMIntent.m",
                     "src/FDMBackup.m", "tests/contract_regression.m"]:
            self.assertIn(name, workflow, f"{name} must be in the Foundation regression line")

    def test_dylib_links_webkit(self):
        workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
        self.assertIn("-framework WebKit", workflow)

    def test_patch_version_is_v20(self):
        workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
        self.assertIn("-DFDM_PATCH_VERSION='\"v20\"'", workflow)
        self.assertIn("--patch-version v20", workflow)
        self.assertIn("FocusDM-v20-", workflow)


class StrictJSONTests(unittest.TestCase):
    def test_parser_rejects_duplicate_keys_in_source(self):
        source = read("FDMJSON.m")
        self.assertIn("对象存在重复键", source)
        # The strict parser must be hand-written; NSJSONSerialization silently last-wins.
        self.assertIn("FDMScanObject", source)
        self.assertNotIn("[NSJSONSerialization JSONObjectWithData", source)

    def test_depth_and_size_bounds_are_declared(self):
        header = read("FDMJSON.h")
        self.assertIn("FDMJSONMaxDepth", header)
        self.assertIn("FDMJSONMaxBytes", header)

    def test_boolean_is_never_a_number(self):
        source = read("FDMJSON.m")
        self.assertIn("CFBooleanGetTypeID", source)


class SitePolicyTests(unittest.TestCase):
    def setUp(self):
        self.header = read("FDMPolicy.h")
        self.source = read("FDMPolicy.m")

    def test_origin_is_exact_scheme_host_port(self):
        self.assertIn("scheme://host:effectivePort", self.header)
        self.assertNotIn("hasSuffix:@\".\"", self.source)

    def test_default_port_is_made_explicit(self):
        self.assertIn('443', self.source)
        self.assertIn('80', self.source)

    def test_unreadable_file_is_preserved_not_overwritten(self):
        self.assertIn("原文件保留", self.source)
        self.assertIn("_writable = NO", self.source)

    def test_inherit_is_not_stored_as_a_value(self):
        self.assertIn("FDMPolicyInherit", self.source)
        self.assertIn("[value isEqual:FDMPolicyInherit]) continue;", self.source)

    def test_global_baseline_is_read_not_hardcoded(self):
        self.assertIn("getCurrentUserAgent", self.source)


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.header = read("FDMBackup.h")
        self.container = read("FDMBackup.m")
        self.coordinator = read("FDMBackupCoordinator.m")

    def test_limits_are_declared_and_enforced(self):
        for name in ["FDMBackupMaxFileBytes", "FDMBackupMaxPayloadBytes", "FDMBackupMaxCategoryBytes",
                     "FDMBackupMaxBookmarks", "FDMBackupMaxScripts", "FDMBackupMaxScriptBytes",
                     "FDMBackupMaxNameBytes", "FDMBackupMaxURLBytes"]:
            self.assertIn(name, self.header)
            self.assertIn(name, self.container)

    def test_base64_is_bounded_before_decode(self):
        self.assertIn("maxEncoded", self.container)

    def test_scripts_are_opt_in_and_disabled_on_import(self):
        self.assertIn("FDMBackupCategoryScripts: @\"用户脚本\"", self.container)
        self.assertIn("return ![category isEqual:FDMBackupCategoryScripts];", self.container)
        self.assertIn('setValue:@NO forKey:@"isActive"', self.coordinator)

    def test_imported_permissions_downgrade_to_ask(self):
        self.assertIn('entry[field] = @"ask"', self.coordinator)

    def test_restore_has_a_journal_and_recovery(self):
        self.assertIn("backup-journal.json", self.coordinator)
        self.assertIn("recoverInterruptedTransaction", self.coordinator)
        self.assertIn("rollbackFailed", self.coordinator)

    def test_secrets_are_never_a_category(self):
        for forbidden in ["FDMBackupCategoryCookie", "resumeData", "password"]:
            self.assertNotIn(forbidden, self.container)


class DownloadIntentTests(unittest.TestCase):
    def setUp(self):
        self.source = read("FDMIntent.m")
        self.engine = read("FDMEngine.m")

    def test_credentials_never_persist(self):
        # The request object lives in an in-memory registry only.
        self.assertIn("_requests = [NSMutableDictionary dictionary]", self.engine)
        self.assertNotIn("request.allHTTPHeaderFields", self.engine)

    def test_redirect_policy_blocks_cross_origin_and_downgrade(self):
        self.assertIn("FDMRedirectRefusal", self.source)
        self.assertIn("https", self.source)
        self.assertIn("已停止以免泄露登录信息", self.source)

    def test_anonymous_session_does_not_share_cookies(self):
        self.assertIn("HTTPShouldSetCookies = NO", self.engine)
        self.assertIn("HTTPCookieStorage = nil", self.engine)

    def test_concurrency_and_queue_limits_exist(self):
        header = read("FDMCommon.h")
        self.assertIn("FDMQueueLimit", header)
        self.assertIn("FDMBatchPreviewLimit", header)
        self.assertIn("concurrencyLimit", read("FDMEngine.h"))

    def test_webkit_download_is_never_retried_as_get(self):
        self.assertIn("FDMTransportWebKitDownload", self.engine)
        self.assertIn("不能改为重新请求", self.engine)

    def test_webkit_download_keeps_the_original_navigation(self):
        webkit = read("FDMWebKitDownloads.m")
        host = read("FocusDM.m")
        self.assertIn("startDownloadUsingRequest:completionHandler:", host)
        self.assertIn("adoptDownload", host)
        # The navigation must be cancelled once the download carries it, not allowed twice.
        self.assertIn("decisionHandler(0)", host)
        self.assertIn("completionEvidence", self.engine)
        self.assertIn("webkit-finish-and-file-confirmed", self.engine)
        # WK resume data is never mixed with URLSession resume data.
        self.assertIn("WKWebView.resumeDownload", webkit)

    def test_webkit_pause_does_not_pretend_to_resume(self):
        self.assertIn("网页原请求下载不支持断点续传", self.engine)


class HostWiringTests(unittest.TestCase):
    def setUp(self):
        self.source = read("FocusDM.m")

    def test_shared_replacement_records_originals_per_class(self):
        # Two navigation delegates share one IMP; a single shared pointer would mis-dispatch.
        self.assertIn("FDMOriginalIMPFor", self.source)
        self.assertIn("FDMInstallClassHook", self.source)

    def test_policy_pages_are_exempt_from_the_navigation_assertion(self):
        for name in ["FDMSitePoliciesViewController", "FDMSitePolicyEditViewController", "FDMBackupViewController"]:
            self.assertIn(name, self.source)

    def test_settings_rows_use_native_models(self):
        self.assertIn("SettingModel", self.source)
        self.assertIn("focusdm://site-policies", self.source)
        self.assertIn("focusdm://backup", self.source)

    def test_no_remove_all_user_scripts(self):
        # A blanket removal would delete the application's own bridge scripts.
        self.assertNotIn("removeAllUserScripts", self.source)


if __name__ == "__main__":
    unittest.main()
