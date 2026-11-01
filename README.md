# GhostGPT native iOS workspace

GhostGPT is a native SwiftUI iOS workspace with chat, a built-in browser, emoji picker, local model selection, and PowerShell/SSH terminal screens. Chat stays compact while typing; speed, provider, and AI capability controls are in **Settings → Chat controls**. Fast mode caps replies at 512 tokens, skips optional model reasoning, and limits sent conversation history to 6,000 characters.

## AI providers and model inventory

GhostGPT supports three explicit providers: **Cloudflare Worker**, **Ollama on the Windows PC**, and **LM Studio on the Windows PC**. The provider selection is persisted, each provider has its own model ID, and switching does not silently fall back to a different provider. Cloudflare requests use the configured HTTPS Worker /chat route; its optional model inventory scan expects the Worker to expose /v1/models. If the Worker does not expose that route, set the model ID manually or add the inventory endpoint to the Worker.

Ollama uses the authenticated PC gateway GET /api/tags and POST /api/chat routes. The gateway only proxies those two Ollama paths to 127.0.0.1:11434; it does not expose Ollama's model-pull or administrative endpoints. LM Studio uses authenticated /control/start, /v1/models, and /v1/chat/completions routes. The app scans inventories and replaces a stale saved model ID only when that ID is no longer advertised.

Open **Settings → AI models** to configure an HTTPS endpoint, enter its token, and scan models. The provider selector is in **Settings → Chat controls**. Cloudflare credentials are stored in a separate iOS Keychain account from PC gateway tokens. Local providers require the PC gateway to be reachable over private Tailscale HTTPS.
## Private PC gateway

The script `windows/lmstudio_gateway.py` implements the authenticated LM Studio proxy/control API, restricted Ollama proxy routes, and a PowerShell endpoint at `/terminal`; it listens only on `127.0.0.1:8767`. Tailscale Serve must expose that loopback service over tailnet-only HTTPS. The current native app defaults to `https://msi.tail28f016.ts.net:10003`; older saved `:10000` settings are migrated on launch. This repository does not install a Windows scheduled task or change Tailscale Serve settings automatically. The authenticated `HEAD /terminal` readiness check verifies that PowerShell is available without running a command.

In the iPhone app, open **Settings → Terminal gateway (PowerShell / SSH)**:
- Endpoint: `https://msi.tail28f016.ts.net:10003/terminal`
- Bearer token: the private token provisioned for the gateway service on the PC (keep it out of chat and source control)

For VPN-free model inference, use the separate public model-only endpoint `https://msi.tail28f016.ts.net/model` with its device token. It does not expose raw model ports or terminal commands. The native app’s private Tailscale model endpoint is `https://msi.tail28f016.ts.net:10003`; its terminal route remains `/terminal`. Keep gateway tokens outside source control and restrict their Windows ACLs. Invalid or missing bearer tokens are rejected, and the model gateway never forwards its device token to LM Studio upstream.

The public model-only endpoint does not require the iPhone to be on the Tailscale VPN, but it still requires the device bearer token. The PowerShell/SSH terminal route remains private to Tailscale and requires its separate bearer token. Neither token is forwarded to LM Studio. The PowerShell route accepts only local PC aliases and the current Windows user, requires explicit approval, restricts default commands to a read-only allow-list, blocks encoded and compound commands, limits execution to 60 seconds, and caps output. Modifying commands are disabled by default and require protected gateway opt-in plus a second in-app confirmation. SSH mode is supported through the same authenticated `/terminal` endpoint using the Windows OpenSSH client, but only for exact aliases listed in the protected `GHOSTGPT_SSH_HOSTS` environment variable (comma-separated). Configure key-based SSH authentication and trusted host keys for the gateway service account; the client uses `BatchMode=yes` and `StrictHostKeyChecking=yes` and will not prompt for passwords or accept unknown host keys. SSH is read-only and limited to an allow-list of commands, rejects compound commands, requires explicit app approval, and has a 25-second execution timeout. If no SSH host aliases are configured, SSH requests are rejected. Do not expose raw shell services to the public internet.

## Browser and tool behavior

The browser tab is an in-app web view. The chat model must not claim to have read a page unless actual page content is supplied. The MCP connector remains available under Settings → MCP connectors.

## AI PowerShell and SSH tool calls

The native chat can use Ollama or LM Studio tool calls for browser actions, reviewed workspace edits, and sequential terminal diagnostics. Configure these in **Settings → Chat controls**. Terminal tools need the private terminal token in iOS Keychain; LM Studio also needs its own model token. The app includes actual tool results in the conversation and stops after eight tool steps.

- Configure **Settings → Terminal gateway (PowerShell / Linux SSH)** with the private HTTPS endpoint and bearer token.
- In **Settings → Chat controls**, select Ollama or LM Studio, then enable the desired browser, workspace, PowerShell, or SSH capabilities.
- Ollama uses the private terminal gateway token. LM Studio uses its separate model token, and uses the terminal token only for terminal or workspace tools.
- The model can request one command at a time, up to eight tool steps per response. Actual command results are shown in chat and returned to the model.
- The Windows gateway remains authoritative. PowerShell is restricted to its read-only allow-list and SSH to exact aliases in `GHOSTGPT_SSH_HOSTS`; compound commands, pipelines, redirection, encoded commands, and credential-oriented operations are blocked. The current startup script configures the trusted Pi host `192.168.7.139` with the Windows OpenSSH client configuration.
- Modifying commands are not automatically executed by the chat tool loop. Use the interactive Agent Workspace / terminal UI for reviewed actions, and only enable gateway-side modification support when you intentionally need it. Do not expose the raw terminal or model APIs publicly.

Cloudflare, Ollama, and LM Studio are supported for ordinary chat; native tool calls are available for Ollama and LM Studio.

## Build an unsigned IPA

The **Build native unsigned iOS IPA** GitHub Actions workflow compiles the native SwiftUI app for simulator and iOS device, packages an unsigned IPA, and uploads it as the `GhostGPT-native-unsigned-iOS-IPA` artifact.

The IPA is unsigned and is not ready for direct installation on a standard iPhone or App Store distribution. It needs signing through an appropriate Apple development workflow.

## Chat history

Recent conversations are stored locally in the app using iOS app storage. The Chats sheet lists the latest 50 conversations and lets you reopen one or start a new chat. Conversation titles use the first user message, truncated for display. This is device-local history; it is not synchronized across devices or uploaded as a cloud archive.

## Current usability and reliability improvements

- Chat history is stored locally (up to 50 recent conversations), searchable by title or message text, and supports reopening, deleting individual conversations, clearing all saved chats with confirmation, and copying a JSON backup to the clipboard.
- Assistant replies include a one-tap copy action.
- The built-in browser has back/forward controls, loading progress, reload, home, and copy-URL actions. Navigation only accepts HTTP/HTTPS URLs; other schemes are rejected, and search terms are encoded as URL query parameters.
- The chat history Done button dismisses the sheet without starting a new conversation.

The project’s Python gateway and workspace tests can be run with `py -3 -m unittest discover -s tests -v`. A successful fresh Xcode build and physical-device validation are still required before treating a revision as release-ready.
