# GhostGPT native iOS workspace

GhostGPT is a native SwiftUI iOS workspace with chat, a built-in browser, emoji picker, speed selection, tool toggles, local model selection, and PowerShell/SSH terminal screens.

## AI providers

- **Cloudflare AI** uses the configured GhostGPT Worker.
- **Ollama on PC** uses the private Tailscale PC gateway and Ollama's `/api/chat` API.
- **LM Studio on PC** uses the private Tailscale PC gateway and the OpenAI-compatible `/v1/chat/completions` API.

Open **Settings → AI models and local model scan**. Select a provider, use the preconfigured PC endpoint, enter the gateway bearer token, and press **Scan PC model inventory**. The current PC inventory includes Ollama models such as `gps-qwen3-fast-8b:latest`, `qwen3.5:9b`, and `deepseek-r1:14b`, plus models served by LM Studio. The default local recommendation is `gps-qwen3-fast-8b:latest` for a lighter first test; model speed depends on hardware load.

## Private PC gateway

The gateway runs on the Windows PC as a scheduled task named **GhostGPT PC Gateway**. Its local backend listens only on `127.0.0.1:8767`; Tailscale Serve exposes HTTPS at `https://msi.tail28f016.ts.net:10000` for the tailnet only. It proxies authenticated requests to Ollama and LM Studio and accepts authenticated terminal requests at `/terminal`.

In the iPhone app, open **Settings → Terminal gateway (PowerShell / SSH)**:
- Endpoint: `https://msi.tail28f016.ts.net:10000/terminal`
- Bearer token: the content of `C:\Users\Administrator\ghost-command-center\ghostgpt-gateway\gateway.token` on the PC

For local model access, open **Settings → AI models and local model scan** and use base endpoint `https://msi.tail28f016.ts.net:10000`. The LM Studio gateway now requires a bearer token for every route, including health, model inventory, startup, and inference. Place a high-entropy token in a `gateway.token` file beside `lmstudio_gateway.py` on the PC, or set `GHOSTGPT_GATEWAY_TOKEN` / `GHOSTGPT_GATEWAY_TOKEN_FILE`; keep the token file outside source control and restrict its Windows ACL. Enter the same token in the app's **AI models** API-key field. An unconfigured gateway fails closed with HTTP 503, and an invalid token receives HTTP 401. The token is not forwarded to LM Studio upstream.

The iPhone must be connected to the same Tailscale tailnet. The gateway validates a bearer token, limits PowerShell to the PC alias (`msi`/localhost), restricts SSH to configured host aliases, and does not expose a raw shell port. AI-generated terminal commands are drafts: review them before pressing Run. Do not share the bearer token or publish this gateway to the public internet.

## Browser and tool behavior

The browser tab is an in-app web view. The AI service can only execute capabilities that the service implements; enabling a tool in the app is not by itself permission for the model to run it. Terminal commands require a separate user action.

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
