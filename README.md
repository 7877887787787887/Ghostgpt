# GhostGPT native iOS workspace

GhostGPT is a native SwiftUI iOS workspace with chat, a built-in browser, emoji picker, speed selection, tool toggles, local model selection, and PowerShell/SSH terminal screens.

## AI providers and model inventory

GhostGPT supports three explicit providers: **Cloudflare Worker**, **Ollama on the Windows PC**, and **LM Studio on the Windows PC**. The provider selection is persisted, each provider has its own model ID, and switching does not silently fall back to a different provider. Cloudflare requests use the configured HTTPS Worker /chat route; its optional model inventory scan expects the Worker to expose /v1/models. If the Worker does not expose that route, set the model ID manually or add the inventory endpoint to the Worker.

Ollama uses the authenticated PC gateway GET /api/tags and POST /api/chat routes. The gateway only proxies those two Ollama paths to 127.0.0.1:11434; it does not expose Ollama's model-pull or administrative endpoints. LM Studio uses authenticated /control/start, /v1/models, and /v1/chat/completions routes. The app scans inventories and replaces a stale saved model ID only when that ID is no longer advertised.

Open **Settings → AI models** to choose a provider, configure its HTTPS endpoint, enter its token, and scan models. Cloudflare credentials are stored under a separate iOS Keychain account from the local PC gateway token. Both local providers require the PC gateway to be reachable over private Tailscale HTTPS.
## Private PC gateway

The script `windows/lmstudio_gateway.py` implements the authenticated LM Studio proxy/control API, restricted Ollama proxy routes, and a PowerShell endpoint at `/terminal`; it listens only on `127.0.0.1:8767`. Configure Tailscale Serve separately to expose that loopback service through a tailnet-only HTTPS endpoint such as `https://msi.tail28f016.ts.net:10000`. This repository does not install a Windows scheduled task or change Tailscale Serve settings automatically. The authenticated `HEAD /terminal` readiness check verifies that PowerShell is available without running a command.

In the iPhone app, open **Settings → Terminal gateway (PowerShell / SSH)**:
- Endpoint: `https://msi.tail28f016.ts.net:10000/terminal`
- Bearer token: the content of `C:\Users\Administrator\ghost-command-center\ghostgpt-gateway\gateway.token` on the PC

For VPN-free model inference, open **Settings → AI models and local model scan** and use base endpoint https://msi.tail28f016.ts.net/model. This public HTTPS path forwards only to the authenticated model-only gateway on the PC; it does not expose raw LM Studio or Ollama ports or terminal commands. The public model token is stored at C:\ProgramData\GhostGPT\public-model.token on the PC and saved in the iOS Keychain after one-time pairing. The private gateway at https://msi.tail28f016.ts.net:10000 remains tailnet-only for private model access and terminal/SSH. Keep both token files outside source control and restrict their Windows ACLs. Invalid or missing bearer tokens are rejected, and the model gateway never forwards its device token to LM Studio upstream.

The public model-only endpoint does not require the iPhone to be on the Tailscale VPN, but it still requires the device bearer token. The PowerShell/SSH terminal route remains private to Tailscale and requires its separate bearer token. Neither token is forwarded to LM Studio. The PowerShell route accepts only local PC aliases and the current Windows user, requires explicit approval, restricts default commands to a read-only allow-list, blocks encoded and compound commands, limits execution to 60 seconds, and caps output. Modifying commands are disabled by default and require protected gateway opt-in plus a second in-app confirmation. SSH mode is supported through the same authenticated `/terminal` endpoint using the Windows OpenSSH client, but only for exact aliases listed in the protected `GHOSTGPT_SSH_HOSTS` environment variable (comma-separated). Configure key-based SSH authentication and trusted host keys for the gateway service account; the client uses `BatchMode=yes` and `StrictHostKeyChecking=yes` and will not prompt for passwords or accept unknown host keys. SSH is read-only and limited to an allow-list of commands, rejects compound commands, requires explicit app approval, and has a 25-second execution timeout. If no SSH host aliases are configured, SSH requests are rejected. Do not expose raw shell services to the public internet.

## Browser and tool behavior

The browser tab is an in-app web view. The selected model can draft plans and commands but does not execute tools by itself. Terminal execution requires a separate configured gateway and explicit user action.

## Build an unsigned IPA

The **Build native unsigned iOS IPA** GitHub Actions workflow runs on pushes to `main`. It compiles the native SwiftUI app for simulator and iOS device, packages an unsigned IPA, and uploads it as the `GhostGPT-native-unsigned-iOS-IPA` artifact.

The IPA is unsigned and is not ready for direct installation on a standard iPhone or App Store distribution. It needs signing through an appropriate Apple development workflow.

## Chat history

Recent conversations are stored locally in the app using iOS app storage. The Chats sheet lists the latest 50 conversations and lets you reopen one or start a new chat. Conversation titles use the first user message, truncated for display. This is device-local history; it is not synchronized across devices or uploaded as a cloud archive.

## Current usability and reliability improvements

- Chat history is stored locally (up to 50 recent conversations), searchable by title or message text, and supports reopening, deleting individual conversations, clearing all saved chats with confirmation, and copying a JSON backup to the clipboard.
- Assistant replies include a one-tap copy action.
- The built-in browser has back/forward controls, loading progress, reload, home, and copy-URL actions. Navigation only accepts HTTP/HTTPS URLs; other schemes are rejected, and search terms are encoded as URL query parameters.
- The chat history Done button dismisses the sheet without starting a new conversation.

These changes are source-committed; a successful fresh CI build and physical-device validation are still required before treating the latest revision as release-ready.