import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCENE = (ROOT / "ios-native" / "SceneDelegate.swift").read_text(encoding="utf-8")
AUTOMATION = (ROOT / "ios-native" / "NativeAutomation.swift").read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")


class NativeAgentToolLoopTests(unittest.TestCase):
    def test_chat_tool_loop_is_opt_in_and_requires_private_tokens(self):
        self.assertIn("private func runNativeAgent(", SCENE)
        self.assertIn("let nativeToolsRequested = terminalReady || aiBrowserToolsEnabled || aiWorkspaceToolsEnabled", SCENE)
        self.assertIn("modelProvider == ModelProvider.ollama.rawValue && nativeToolsRequested", SCENE)
        self.assertIn("modelProvider == ModelProvider.lmStudio.rawValue && nativeToolsRequested", SCENE)
        self.assertIn('let terminalToken = KeychainStore.migratedValue(for: "terminalGatewayToken")', AUTOMATION)
        self.assertIn('let modelToken = isOllama ? terminalToken : KeychainStore.migratedValue(for: "localModelAPIKey")', AUTOMATION)
        self.assertIn("guard !modelToken.isEmpty", AUTOMATION)

    def test_ollama_uses_private_terminal_gateway_and_separate_keychain_account(self):
        self.assertIn('case .ollama: return "terminalGatewayToken"', SCENE)
        self.assertIn('UserDefaults.standard.string(forKey: "terminalGatewayURL")', SCENE)
        self.assertIn('components.path = action', AUTOMATION)
        self.assertIn('chatURL = try gatewayURL("/api/chat")', AUTOMATION)
        self.assertIn('LocalModelClient.validatedBaseURL(configuration.terminalEndpoint', AUTOMATION)

    def test_agent_commands_are_explicitly_approved_read_only_requests(self):
        start = AUTOMATION.index("private func command(")
        end = AUTOMATION.index("private func workspace(", start)
        command = AUTOMATION[start:end]
        self.assertIn('"approved": true', command)
        self.assertIn('"riskConfirmed": false', command)
        self.assertIn('configuration.terminalModes.contains(mode)', command)
        self.assertIn('"ok": (200..<300).contains(status) && body["ok"] as? Bool == true && body["exit_code"] as? Int == 0', command)
        engine = AUTOMATION[AUTOMATION.index("func run(history:"):AUTOMATION.index("private func command(")]
        self.assertIn("for step in 0..<8", engine)
        self.assertIn("guard calls.count == 1", engine)
        self.assertIn('toolReply["tool_call_id"] = callID', engine)

    def test_lm_studio_agent_uses_openai_tools_and_separate_gateway_credentials(self):
        self.assertIn('chatURL = try LocalModelClient.validatedBaseURL(configuration.modelEndpoint, provider: .lmStudio)', AUTOMATION)
        self.assertIn('.appendingPathComponent("v1/chat/completions")', AUTOMATION)
        self.assertIn('payload["tool_choice"] = "auto"', AUTOMATION)
        self.assertIn('let modelToken = isOllama ? terminalToken : KeychainStore.migratedValue(for: "localModelAPIKey")', AUTOMATION)
        self.assertIn('post(chatURL, token: modelToken', AUTOMATION)
        self.assertIn('post(gatewayURL("/terminal"), token: token', AUTOMATION)
        self.assertNotIn('ollamaModelID', AUTOMATION[AUTOMATION.index("final class NativeAgentEngine"):])

    def test_gateway_policy_and_docs_keep_mutations_out_of_automatic_chat_tools(self):
        self.assertIn("GHOSTGPT_ALLOW_MODIFYING_COMMANDS", (ROOT / "windows" / "lmstudio_gateway.py").read_text(encoding="utf-8"))
        self.assertIn("Modifying commands are not automatically executed", README)
        self.assertIn("GHOSTGPT_SSH_HOSTS", README)


if __name__ == "__main__":
    unittest.main()
