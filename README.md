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

For local model access, open **Settings → AI models and local model scan** and use base endpoint `https://msi.tail28f016.ts.net:10000`. The LM Studio gateway now requires a bearer token for every route, including health, model inventory, startup, and inference. Place a high-entropy token in a `gateway.token` file beside `lmstudio_gateway.py` on the PC, or set `GHOSTGPT_GATEWAY_TOKEN` / `GHOSTGPT_GATEWAY_TOKEN_FILE`; keep the token file outside source control and restrict its Windows ACL. Enter the same token in the app's **AI models** API-key field. An unconfigured gateway fails closed with HTTP 503, and an invalid token receives HTTP 401. The token is not forwarded to LM Studio upstream.

The iPhone must be connected to the same Tailscale tailnet. Both model and PowerShell routes require the bearer token; the token is never forwarded to LM Studio. The PowerShell route accepts only the local PC aliases and the current Windows user, requires an explicit approval flag, restricts default commands to a read-only allow-list, blocks encoded, nested-expression, and compound commands, limits execution to 60 seconds, and caps returned output. Startup logs report token configuration and PowerShell readiness without logging secrets. Modifying commands are disabled by default; enabling them requires `GHOSTGPT_ALLOW_MODIFYING_COMMANDS=1` in the protected gateway environment plus a second in-app confirmation. SSH mode is not implemented by this gateway and needs a separate SSH gateway. Do not expose raw shell services to the public internet.

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
