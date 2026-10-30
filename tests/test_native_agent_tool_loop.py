import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "ios-native" / "SceneDelegate.swift").read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")


class NativeAgentToolLoopTests(unittest.TestCase):
    def test_chat_tool_loop_is_opt_in_and_requires_ollama_and_private_token(self):
        self.assertIn('private func runOllamaAgent(history:', SOURCE)
        self.assertIn('modelProvider == ModelProvider.ollama.rawValue && aiTerminalToolsEnabled', SOURCE)
        self.assertIn('!KeychainStore.migratedValue(for: "terminalGatewayToken").isEmpty', SOURCE)
        self.assertIn('Toggle("AI terminal tool calls (Ollama)"', SOURCE)

    def test_ollama_uses_private_terminal_gateway_and_separate_keychain_account(self):
        self.assertIn('case .ollama: return "terminalGatewayToken"', SOURCE)
        self.assertIn('UserDefaults.standard.string(forKey: "terminalGatewayURL")', SOURCE)
        self.assertIn('gatewayComponents.path = "/api/chat"', SOURCE)
        self.assertIn('components.path = ""', SOURCE)

    def test_agent_executes_only_explicitly_approved_read_only_lane(self):
        start = SOURCE.index('private func runOllamaAgent(history:')
        end = SOURCE.index('private func retryLastMessage()', start)
        agent = SOURCE[start:end]
        self.assertIn('"approved": true', agent)
        self.assertIn('"riskConfirmed": false', agent)
        self.assertIn('for step in 0..<5', agent)
        self.assertIn('guard calls.count == 1', agent)
        self.assertIn('working.append(["role": "tool", "tool_name": name, "content": evidenceText])', agent)
        self.assertIn('messages.append(ChatMessage(text: "Tool result', agent)
        self.assertNotIn('"riskConfirmed": true', agent)


    def test_lm_studio_agent_uses_openai_tools_and_separate_gateway_credentials(self):
        self.assertIn('modelProvider == ModelProvider.lmStudio.rawValue && aiTerminalToolsEnabled', SOURCE)
        start = SOURCE.index('private func runLMStudioAgent(history:')
        end = SOURCE.index('private func retryLastMessage()', start)
        agent = SOURCE[start:end]
        self.assertIn('localModelEndpoint', agent)
        self.assertIn('v1/chat/completions', agent)
        self.assertIn('choices.first?["message"]', agent)
        self.assertIn('"tool_choice": "auto"', agent)
        self.assertIn('KeychainStore.migratedValue(for: "localModelAPIKey")', agent)
        self.assertIn('KeychainStore.migratedValue(for: "terminalGatewayToken")', agent)
        self.assertIn('Bearer \\(modelToken)', agent)
        self.assertIn('Bearer \\(terminalToken)', agent)
        self.assertIn('"tool_call_id": toolCallID', agent)
        self.assertIn('"riskConfirmed": false', agent)
        self.assertNotIn('ollamaModelID', agent)
        self.assertNotIn('api/chat', agent)

    def test_gateway_policy_and_docs_keep_mutations_out_of_automatic_chat_tools(self):
        self.assertIn('GHOSTGPT_ALLOW_MODIFYING_COMMANDS', (ROOT / "windows" / "lmstudio_gateway.py").read_text(encoding="utf-8"))
        self.assertIn('Modifying commands are not automatically executed', README)
        self.assertIn('GHOSTGPT_SSH_HOSTS', README)


if __name__ == "__main__":
    unittest.main()
