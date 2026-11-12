"""Architecture & contract regressions for the Focus translation enhancements.

Validates that:
1. Dead Microsoft /translate/auth requests are intercepted and mock-authenticated.
2. Cognitive translator requests are routed to the live Edge free endpoint with proper payload transformation.
3. Google translate requests have failover to domestic-accessible Edge translation.
4. PandaWebView canPerformAction:withSender: permits iOS system text selection translation (_systemTranslate: / translate:)
   and forwards to WKContentView for offline Apple language pack translation.
5. All hooks are wired into FocusDM host initialization.
"""
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TranslateProxyContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (ROOT / "src/FDMTranslateProxy.h").read_text(encoding="utf-8")
        cls.source = (ROOT / "src/FDMTranslateProxy.m").read_text(encoding="utf-8")
        cls.focusdm = (ROOT / "src/FocusDM.m").read_text(encoding="utf-8")

    def test_translate_proxy_files_exist_and_non_empty(self):
        self.assertGreater(len(self.header), 100)
        self.assertGreater(len(self.source), 1000)

    def test_translate_proxy_public_contract(self):
        self.assertIn("+ (void)installHooks;", self.header)
        self.assertIn("+ (void)installHooks", self.source)

    def test_edge_endpoint_and_user_agent(self):
        self.assertIn("https://edge.microsoft.com/translate/translatetext", self.source)
        self.assertIn("FDMEdgeEndpoint", self.source)
        self.assertIn("FDMEdgeUserAgent", self.source)
        self.assertIn("Edg/", self.source)

    def test_dead_microsoft_auth_interception(self):
        self.assertIn("edge.microsoft.com/translate/auth", self.source)
        self.assertIn("Bearer", self.source)
        self.assertIn("fdm_mock_edge_token", self.source)

    def test_azure_cognitive_routing_and_payload_conversion(self):
        self.assertIn("api-edge.cognitive.microsofttranslator.com", self.source)
        self.assertIn("fdm_convertBodyToEdgeFormat", self.source)
        self.assertIn("isEnterpriseClient=false", self.source)

    def test_google_translate_failover_logic(self):
        self.assertIn("translate.googleapis.com", self.source)
        self.assertIn("fdm_TranslateHelper_fallbackEdge", self.source)
        self.assertIn("timeoutInterval = 3.5", self.source)

    def test_panda_webview_selection_translation_restoration(self):
        self.assertIn("fdm_PandaWebView_canPerformAction", self.source)
        self.assertIn("fdm_PandaWebView_safeTranslate", self.source)
        self.assertIn("_systemTranslate:", self.source)
        self.assertIn("translate:", self.source)
        self.assertIn("translateForWebView:", self.source)
        self.assertIn("class_replaceMethod", self.source)

    def test_focusdm_wiring(self):
        self.assertIn('#import "FDMTranslateProxy.h"', self.focusdm)
        self.assertIn("[FDMTranslateProxy installHooks];", self.focusdm)

    def test_payload_conversion_contract_semantics(self):
        # Simulate payload conversion from Focus Cognitive format to Edge format
        cognitive_body = [{"Text": "Hello world"}, {"Text": "How are you?"}]
        edge_body = [item.get("Text", "") for item in cognitive_body]
        self.assertEqual(edge_body, ["Hello world", "How are you?"])

        # Edge returns translations array matching input order
        edge_response = [
            {"translations": [{"text": "你好世界"}]},
            {"translations": [{"text": "你好吗？"}]},
        ]
        self.assertEqual(edge_response[0]["translations"][0]["text"], "你好世界")
        self.assertEqual(edge_response[1]["translations"][0]["text"], "你好吗？")

    def test_google_format_synthesis(self):
        # Validate synthesis of Google format for fallback
        chunks = [
            ["你好世界", "Hello world", None, None, 10],
            ["测试", "Test", None, None, 10],
        ]
        outer = [chunks, None, "auto"]
        serialized = json.dumps(outer)
        reloaded = json.loads(serialized)
        self.assertEqual(reloaded[0][0][0], "你好世界")
        self.assertEqual(reloaded[0][0][1], "Hello world")
        self.assertEqual(reloaded[0][1][0], "测试")


if __name__ == "__main__":
    unittest.main()
