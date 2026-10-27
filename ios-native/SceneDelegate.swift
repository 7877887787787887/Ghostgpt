import UIKit
import SwiftUI
import WebKit

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let text: String
    let isUser: Bool
}

struct ChatSession: Identifiable, Codable {
    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
}

struct AIReply: Decodable { let reply: String }
struct AIError: Decodable { let error: String }
struct OllamaTags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
struct OpenAIModels: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
struct OpenAIChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
struct OllamaChatResponse: Decodable { let message: Message; struct Message: Decodable { let content: String } }

enum GhostTool: String, CaseIterable, Identifiable {
    case browser = "Browser"
    case powershell = "PowerShell"
    case ssh = "SSH"
    case plugins = "Plugins"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .browser: return "globe"
        case .powershell: return "terminal"
        case .ssh: return "server.rack"
        case .plugins: return "puzzlepiece.extension"
        }
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: GhostGPTRootView())
        self.window = window
        window.makeKeyAndVisible()
    }
}

struct GhostGPTRootView: View {
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ChatView() }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }.tag(0)
            NavigationStack { BrowserView() }
                .tabItem { Label("Browser", systemImage: "globe") }.tag(1)
            NavigationStack { ToolsView() }
                .tabItem { Label("Tools", systemImage: "terminal") }.tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        .tint(Color(red: 0.36, green: 0.56, blue: 1.0))
        .preferredColorScheme(.dark)
    }
}

struct ChatView: View {
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @AppStorage("speedMode") private var speedMode = "Balanced"
    @AppStorage("modelProvider") private var modelProvider = "Cloudflare"
    @AppStorage("localModelEndpoint") private var localModelEndpoint = "https://msi.tail28f016.ts.net:10000"
    @AppStorage("localModelID") private var localModelID = "gps-qwen3-fast-8b:latest"
    @AppStorage("localModelAPIKey") private var localModelAPIKey = ""
    @AppStorage("enabledToolsJSON") private var enabledToolsJSON = "[\"Browser\"]"
    @AppStorage("savedChatsJSON") private var savedChatsJSON = "[]"
    @State private var draft = ""
    @State private var messages: [ChatMessage] = []
    @State private var currentChatID = UUID()
    @State private var isConnecting = false
    @State private var errorText: String?
    @State private var showingTools = false
    @State private var showingHistory = false
    @State private var activeTool: GhostTool?
    @FocusState private var composerFocused: Bool

    private let quickPrompts = [
        ("Search the web", "Find current information about "),
        ("Write code", "Help me write and debug code for "),
        ("Use a terminal", "Help me plan a safe terminal command for ")
    ]

    private var enabledTools: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(enabledToolsJSON.utf8))) ?? ["Browser"]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { showingHistory = true } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 19, weight: .medium))
                        .frame(width: 40, height: 40).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityLabel("Chat history and navigation")
                VStack(alignment: .leading, spacing: 2) {
                    Text("GhostGPT").font(.headline)
                    Text("AI workspace").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker("Response speed", selection: $speedMode) {
                        Text("Fast").tag("Fast")
                        Text("Balanced").tag("Balanced")
                        Text("Deep").tag("Deep")
                    }
                    Picker("AI model source", selection: $modelProvider) {
                        Text("Cloud AI").tag("Cloudflare")
                        Text("Ollama on PC").tag("Ollama")
                        Text("LM Studio on PC").tag("LM Studio")
                    }
                    Divider()
                    ForEach(GhostTool.allCases) { tool in
                        Button { activeTool = tool } label: { Label(tool.rawValue, systemImage: tool.icon) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                        Text(speedMode).font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2)
                    }.padding(.horizontal, 10).padding(.vertical, 9)
                        .background(.white.opacity(0.07), in: Capsule())
                }
            }.padding(.horizontal).padding(.top, 8).padding(.bottom, 10)

            if messages.isEmpty {
                ScrollView {
                    VStack(spacing: 20) {
                        Spacer(minLength: 38)
                        ZStack {
                            RoundedRectangle(cornerRadius: 27).fill(
                                LinearGradient(colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            ).frame(width: 82, height: 82)
                            Image(systemName: "sparkles").font(.system(size: 35, weight: .medium)).foregroundStyle(.white)
                        }
                        VStack(spacing: 7) {
                            Text("What can I help with?").font(.system(size: 28, weight: .bold, design: .rounded))
                            Text("Ask GhostGPT, browse, or open a tool.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(quickPrompts, id: \.0) { item in
                                Button {
                                    draft = item.1
                                    composerFocused = true
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(item.0).font(.subheadline.weight(.semibold))
                                        Text(item.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, minHeight: 88, alignment: .leading).padding(13)
                                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07), lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 8) {
                            Label("Tools ready to configure", systemImage: "wrench.and.screwdriver")
                            Spacer()
                            Button("Open tools") { activeTool = .plugins }.font(.caption.weight(.semibold))
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }.padding(.horizontal, 18).padding(.bottom, 24)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(messages) { message in
                                MessageBubble(message: message).id(message.id)
                            }
                            if isConnecting {
                                HStack(spacing: 10) {
                                    ProgressView().tint(.blue)
                                    Text("GhostGPT is thinking…").foregroundStyle(.secondary).font(.subheadline)
                                }.padding(.vertical, 8)
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 20)
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }

            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorText).font(.caption)
                    Spacer()
                    Button { self.errorText = nil } label: { Image(systemName: "xmark") }
                }.foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 8)
            }

            VStack(spacing: 10) {
                if showingTools {
                    toolStrip
                }
                HStack(alignment: .bottom, spacing: 9) {
                    Button { withAnimation(.spring(response: 0.25)) { showingTools.toggle() } } label: {
                        Image(systemName: showingTools ? "xmark" : "plus")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.09), in: Circle())
                    }.accessibilityLabel("Add tools and plugins")
                    Menu {
                        ForEach(["😀", "😂", "🔥", "❤️", "👍", "🤔", "🚀", "✨", "😎", "🎯"], id: \.self) { emoji in
                            Button(emoji) { draft += emoji }
                        }
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 34, height: 42)
                    }.accessibilityLabel("Insert emoji")
                    TextField("Message GhostGPT", text: $draft, axis: .vertical)
                        .lineLimit(1...5).focused($composerFocused)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
                        .submitLabel(.send)
                    Button { send() } label: {
                        Image(systemName: isConnecting ? "hourglass" : "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 42, height: 42)
                            .background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting ? Color.gray.opacity(0.5) : Color.white, in: Circle())
                    }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                }
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                    Text("\(speedMode) mode")
                    Text("·")
                    Text(enabledTools.isEmpty ? "No tools selected" : "\(enabledTools.count) tool(s) enabled")
                    Spacer()
                }.font(.caption2).foregroundStyle(.tertiary).padding(.leading, 54)
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
                .background(.ultraThinMaterial)
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: messages.count) { _ in persistCurrentChat() }
        .sheet(isPresented: $showingHistory) {
            ChatHistorySheet(
                savedChatsJSON: savedChatsJSON,
                onNewChat: {
                    persistCurrentChat()
                    currentChatID = UUID()
                    messages = []
                    errorText = nil
                    showingHistory = false
                },
                onSelect: { session in
                    currentChatID = session.id
                    messages = session.messages
                    errorText = nil
                    showingHistory = false
                }
            )
        }
        .sheet(item: $activeTool) { tool in
            NavigationStack {
                switch tool {
                case .browser: BrowserView()
                case .powershell: TerminalGatewayView(mode: "powershell")
                case .ssh: TerminalGatewayView(mode: "ssh")
                case .plugins: PluginsView()
                }
            }
        }
    }

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(GhostTool.allCases) { tool in
                    Button { activeTool = tool } label: {
                        Label(tool.rawValue, systemImage: tool.icon)
                            .font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(.white.opacity(0.07), in: Capsule())
                    }.buttonStyle(.plain)
                }
                Menu {
                    Picker("Speed", selection: $speedMode) {
                        Text("Fast").tag("Fast"); Text("Balanced").tag("Balanced"); Text("Deep").tag("Deep")
                    }
                } label: {
                    Label("Speed", systemImage: "speedometer").font(.caption.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 10).background(.white.opacity(0.07), in: Capsule())
                }
            }.padding(.horizontal, 3)
        }
    }

    private func persistCurrentChat() {
        guard !messages.isEmpty,
              let data = savedChatsJSON.data(using: .utf8) else { return }
        var sessions = (try? JSONDecoder().decode([ChatSession].self, from: data)) ?? []
        let title = messages.first(where: { $0.isUser })?.text ?? "New chat"
        let session = ChatSession(id: currentChatID, title: String(title.prefix(64)), messages: messages, updatedAt: Date())
        if let index = sessions.firstIndex(where: { $0.id == currentChatID }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        sessions = Array(sessions.prefix(50))
        if let encoded = try? JSONEncoder().encode(sessions) {
            savedChatsJSON = String(data: encoded, encoding: .utf8) ?? "[]"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(text: text, isUser: true))
        draft = ""
        errorText = nil
        isConnecting = true
        showingTools = false
        Task {
            defer { isConnecting = false }
            do {
                let history = messages.map { ["role": $0.isUser ? "user" : "assistant", "content": $0.text] }
                if modelProvider == "Cloudflare" {
                    guard let baseURL = URL(string: serviceURL), baseURL.scheme == "https" else {
                        throw NSError(domain: "GhostGPT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a valid HTTPS service URL in Settings."])
                    }
                    var request = URLRequest(url: baseURL.appendingPathComponent("chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = speedMode == "Fast" ? 25 : 75
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "message": text,
                        "messages": history,
                        "speed": speedMode.lowercased(),
                        "model": localModelID,
                        "tools": enabledTools
                    ])
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    if (200..<300).contains(http.statusCode), let answer = try? JSONDecoder().decode(AIReply.self, from: data) {
                        messages.append(ChatMessage(text: answer.reply, isUser: false))
                    } else {
                        let serviceError = try? JSONDecoder().decode(AIError.self, from: data)
                        throw NSError(domain: "GhostGPT", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: serviceError?.error ?? "The AI service returned HTTP \(http.statusCode)."])
                    }
                } else {
                    try await sendToLocalModel(history: history)
                }
            } catch {
                errorText = error.localizedDescription == "The operation couldn’t be completed. (NSURLErrorDomain error -1009.)"
                    ? "No internet connection. Reconnect and try again."
                    : "GhostGPT request failed: \(error.localizedDescription)"
            }
        }
    }

    private func sendToLocalModel(history: [[String: String]]) async throws {
        let cleaned = localModelEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: cleaned), base.scheme == "https" else {
            throw NSError(domain: "GhostGPT", code: 2, userInfo: [NSLocalizedDescriptionKey: "Set a private HTTPS Tailscale URL for your PC's model gateway in Settings → AI models."])
        }
        let path = modelProvider == "Ollama" ? "api/chat" : "v1/chat/completions"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !localModelAPIKey.isEmpty { request.setValue("Bearer \(localModelAPIKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = speedMode == "Fast" ? 45 : 180
        if modelProvider == "Ollama" {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": localModelID,
                "stream": false,
                "think": false,
                "messages": history,
                "options": ["num_predict": speedMode == "Fast" ? 128 : 512, "num_ctx": 4096]
            ])
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": localModelID,
                "stream": false,
                "messages": history,
                "max_tokens": speedMode == "Fast" ? 128 : 512
            ])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GhostGPT", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Local model returned HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "No response body")"])
        }
        let reply: String
        if modelProvider == "Ollama" {
            reply = try JSONDecoder().decode(OllamaChatResponse.self, from: data).message.content
        } else {
            reply = try JSONDecoder().decode(OpenAIChatResponse.self, from: data).choices.first?.message.content ?? "The local model returned an empty response."
        }
        messages.append(ChatMessage(text: reply, isUser: false))
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !message.isUser {
                Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(.blue)
                    .frame(width: 30, height: 30).background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            } else { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 7) {
                Text(message.text).textSelection(.enabled).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                if !message.isUser {
                    HStack(spacing: 14) {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                        }
                        .accessibilityLabel("Copy assistant response")
                        Spacer(minLength: 0)
                    }.foregroundStyle(.secondary).padding(.top, 3)
                }
            }.padding(message.isUser ? 12 : 2)
                .background(message.isUser ? Color.blue.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 17))
            if message.isUser {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 25)).foregroundStyle(.secondary)
            } else { Spacer(minLength: 8) }
        }
    }
}

struct BrowserView: View {
    @State private var address = "https://www.google.com"
    @State private var currentURL = "https://www.google.com"
    @State private var reloadToken = UUID()
    @FocusState private var addressFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.green)
                TextField("Search or enter URL", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .focused($addressFocused).submitLabel(.go)
                    .onSubmit { navigate() }
                Button { navigate() } label: { Image(systemName: "arrow.right.circle.fill").font(.title2) }
            }.padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14)).padding(12)
            EmbeddedBrowser(urlString: currentURL, reloadToken: reloadToken)
            HStack {
                Button { reloadToken = UUID() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                Spacer()
                Button { address = "https://www.google.com"; navigate() } label: { Label("Home", systemImage: "house") }
                Spacer()
                Button { UIPasteboard.general.string = currentURL } label: { Label("Copy URL", systemImage: "doc.on.doc") }
            }.font(.caption).padding(12).background(.ultraThinMaterial)
        }
        .navigationTitle("Ghost Browser").navigationBarTitleDisplayMode(.inline)
    }
    private func navigate() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains(" ") || (!trimmed.contains(".") && !trimmed.hasPrefix("http")) {
            currentURL = "https://www.google.com/search?q=" + (trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        } else {
            currentURL = trimmed.contains("://") ? trimmed : "https://" + trimmed
        }
        addressFocused = false
    }
}

struct EmbeddedBrowser: UIViewRepresentable {
    let urlString: String
    let reloadToken: UUID
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.allowsBackForwardNavigationGestures = true
        return view
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastURL != urlString, let url = URL(string: urlString) {
            context.coordinator.lastURL = urlString
            webView.load(URLRequest(url: url))
        }
        if context.coordinator.lastReload != reloadToken {
            context.coordinator.lastReload = reloadToken
            if context.coordinator.lastURL == urlString { webView.reload() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator {
        var lastURL = ""
        var lastReload = UUID()
    }
}

struct ToolsView: View {
    var body: some View {
        List {
            Section("Built-in tools") {
                NavigationLink { BrowserView() } label: { Label("Ghost Browser", systemImage: "globe") }
                NavigationLink { TerminalGatewayView(mode: "powershell") } label: { Label("PowerShell terminal", systemImage: "terminal") }
                NavigationLink { TerminalGatewayView(mode: "ssh") } label: { Label("SSH terminal", systemImage: "server.rack") }
                NavigationLink { PluginsView() } label: { Label("Plugins & capabilities", systemImage: "puzzlepiece.extension") }
            }
            Section("Execution requirements") {
                Text("The browser runs in the app. PowerShell and SSH require a secure terminal gateway that you control; the app does not execute shell commands locally or expose credentials to GhostGPT.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Tools")
    }
}

struct PluginsView: View {
    @AppStorage("enabledToolsJSON") private var enabledToolsJSON = "[\"Browser\"]"
    @State private var selected: Set<String> = ["Browser"]
    private let tools: [(String, String, String)] = [
        ("Browser", "Search and open websites inside GhostGPT.", "globe"),
        ("PowerShell", "Run commands through your configured Windows terminal gateway.", "terminal"),
        ("SSH", "Connect to remote servers through your configured SSH gateway.", "server.rack"),
        ("File tools", "Prepare files and command snippets for review.", "doc.text")
    ]
    var body: some View {
        List {
            Section("Available capabilities") {
                ForEach(tools, id: \.0) { tool in
                    Toggle(isOn: Binding(get: { selected.contains(tool.0) }, set: { enabled in
                        if enabled { selected.insert(tool.0) } else { selected.remove(tool.0) }
                        save()
                    })) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.0).font(.body.weight(.medium))
                                Text(tool.1).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: tool.2).frame(width: 25) }
                    }
                    .tint(.blue)
                }
            }
            Section {
                Text("Enabling a capability adds it to the app's selected tool list. The AI service must support a tool before it can execute it. Terminal execution additionally requires a configured gateway.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Plugins & tools")
        .onAppear { selected = Set((try? JSONDecoder().decode([String].self, from: Data(enabledToolsJSON.utf8))) ?? ["Browser"]) }
    }
    private func save() { enabledToolsJSON = String(data: (try? JSONEncoder().encode(Array(selected).sorted())) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
}

struct TerminalGatewayView: View {
    let mode: String
    @AppStorage("terminalGatewayURL") private var gatewayURL = "https://msi.tail28f016.ts.net:10000/terminal"
    @AppStorage("terminalGatewayToken") private var gatewayToken = ""
    @State private var host = ""
    @State private var username = ""
    @State private var command = ""
    @State private var taskDescription = ""
    @State private var output = "Connect a trusted terminal gateway in Settings to execute commands. No command has been run."
    @State private var running = false
    @State private var drafting = false
    @AppStorage("serviceURL") private var aiServiceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @AppStorage("speedMode") private var speedMode = "Balanced"
    @State private var showingSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(mode == "ssh" ? "SSH terminal" : "PowerShell terminal", systemImage: mode == "ssh" ? "server.rack" : "terminal")
                .font(.title2.bold())
            Text(mode == "ssh"
                 ? "Send commands to a remote SSH gateway you control."
                 : "Send commands to a Windows PowerShell gateway you control.")
                .font(.subheadline).foregroundStyle(.secondary)
            if gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Gateway not configured", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Configure gateway") { showingSettings = true }.buttonStyle(.borderedProminent)
            } else {
                TextField(mode == "ssh" ? "user@host or server alias" : "Windows host or session name", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                TextField("Username (if required by gateway)", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                ScrollView {
                    Text(output).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(minHeight: 140).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 8) {
                    TextField(mode == "ssh" ? "Command to run…" : "PowerShell command…", text: $command, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    Button { Task { await execute() } } label: {
                        Image(systemName: running ? "hourglass" : "arrow.up.circle.fill").font(.title)
                    }.accessibilityLabel("Run reviewed command")
                     .disabled(running || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.isEmpty)
                }
                TextField("Describe a task for AI to draft a command…", text: $taskDescription, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                Button {
                    Task { await draftCommand() }
                } label: {
                    Label(drafting ? "Drafting…" : "Draft command with AI", systemImage: "sparkles")
                }.buttonStyle(.bordered).disabled(drafting || taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("AI drafts only. Review the command above before pressing Run.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Change gateway") { showingSettings = true }.font(.caption)
            }
            Spacer()
            Text("Security: only use a gateway you trust. Review commands before running them. Credentials should be handled by the gateway, not pasted into chat.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding()
            .navigationTitle(mode == "ssh" ? "SSH" : "PowerShell")
            .onAppear { if host.isEmpty { host = mode == "ssh" ? "raspberrypi" : "msi" } }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { TerminalGatewaySettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } } } }
            }
    }

    private func draftCommand() async {
        let task = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        drafting = true
        defer { drafting = false }
        do {
            guard let base = URL(string: aiServiceURL), base.scheme == "https" else {
                throw NSError(domain: "GhostGPT", code: 4, userInfo: [NSLocalizedDescriptionKey: "Configure a valid HTTPS AI service URL in Settings."])
            }
            var request = URLRequest(url: base.appendingPathComponent("chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = speedMode == "Fast" ? 25 : 75
            let shell = mode == "ssh" ? "POSIX shell" : "Windows PowerShell"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "message": "Draft exactly one \(shell) command for this task: \(task). Return only the command, no Markdown fences or explanation. Prefer read-only inspection. Do not use destructive commands, change security settings, delete files, or expose credentials.",
                "speed": speedMode.lowercased(),
                "tools": []
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let answer = try? JSONDecoder().decode(AIReply.self, from: data) else {
                throw NSError(domain: "GhostGPT", code: 5, userInfo: [NSLocalizedDescriptionKey: "AI could not draft a command."])
            }
            command = answer.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            output += "\n\nAI command draft failed: \(error.localizedDescription)"
        }
    }

    private func execute() async {
        guard let base = URL(string: gatewayURL), base.scheme == "https" else {
            output = "Gateway URL must be a valid HTTPS address."
            return
        }
        let submitted = command
        command = ""
        running = true
        defer { running = false }
        do {
            var request = URLRequest(url: base)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !gatewayToken.isEmpty { request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization") }
            request.timeoutInterval = 30
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "mode": mode, "host": host, "username": username, "command": submitted
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let body = String(data: data, encoding: .utf8) ?? "(Non-text response)"
            if (200..<300).contains(http.statusCode) {
                output += "\n\n$ \(submitted)\n\(body)"
            } else {
                output += "\n\nRequest failed (HTTP \(http.statusCode)):\n\(body)"
            }
        } catch {
            output += "\n\nConnection failed: \(error.localizedDescription)"
        }
    }
}

struct TerminalGatewaySettingsView: View {
    @AppStorage("terminalGatewayURL") private var gatewayURL = "https://msi.tail28f016.ts.net:10000/terminal"
    @AppStorage("terminalGatewayToken") private var gatewayToken = ""
    var body: some View {
        Form {
            Section("Secure terminal gateway") {
                TextField("HTTPS gateway endpoint URL", text: $gatewayURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                SecureField("Gateway bearer token", text: $gatewayToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Gateway must accept POST JSON fields mode, host, username, and command, authenticate the Bearer token, and enforce host/command allow-lists. The app does not provide a shell server itself.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Security") {
                Text("Do not expose a raw PowerShell or SSH endpoint to the public internet. Use authentication, per-user authorization, host allow-lists, audit logs, rate limits, and TLS.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Terminal gateway")
    }
}

struct ChatHistorySheet: View {
    let savedChatsJSON: String
    let onNewChat: () -> Void
    let onSelect: (ChatSession) -> Void
    @Environment(\.dismiss) private var dismiss

    private var sessions: [ChatSession] {
        guard let data = savedChatsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChatSession].self, from: data)) ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: onNewChat) { Label("New chat", systemImage: "square.and.pencil") }
                }
                Section("Saved conversations") {
                    if sessions.isEmpty {
                        Text("Your conversations will appear here automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(sessions) { session in
                            Button { onSelect(session) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.title).font(.body).lineLimit(2)
                                    Text("\(session.messages.count) messages · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.navigationTitle("Chats")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @AppStorage("speedMode") private var speedMode = "Balanced"
    var body: some View {
        List {
            Section("GhostGPT") {
                Label("Native SwiftUI interface", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("AI endpoint configured", systemImage: "cloud.fill").foregroundStyle(.blue)
                Text("The endpoint is configured; connection status is checked when you send a message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preferences") {
                Picker("Response speed", selection: $speedMode) {
                    Text("Fast").tag("Fast"); Text("Balanced").tag("Balanced"); Text("Deep").tag("Deep")
                }
                Toggle("Notifications", isOn: $notificationsEnabled)
            }
            Section("Tools") {
                NavigationLink("Plugins & capabilities") { PluginsView() }
                NavigationLink("AI models and local model scan") { LocalModelsSettingsView() }
                NavigationLink("Terminal gateway (PowerShell / SSH)") { TerminalGatewaySettingsView() }
                NavigationLink("Browser") { BrowserView() }
            }
            Section("Connection") {
                NavigationLink("Advanced connection settings") { AdvancedSettingsView() }
            }
            Section("Policies") {
                Link("Privacy Policy", destination: URL(string: "https://ghostgpt.live/privacy")!)
                Link("Terms of Use", destination: URL(string: "https://ghostgpt.live/terms")!)
            }
            Section { Text("GhostGPT • Native iOS workspace").foregroundStyle(.secondary) }
        }.navigationTitle("Settings")
    }
}

struct LocalModelsSettingsView: View {
    @AppStorage("modelProvider") private var modelProvider = "Cloudflare"
    @AppStorage("localModelEndpoint") private var localModelEndpoint = "https://msi.tail28f016.ts.net:10000"
    @AppStorage("localModelID") private var localModelID = "gps-qwen3-fast-8b:latest"
    @AppStorage("localModelAPIKey") private var localModelAPIKey = ""
    @State private var availableModels: [String] = []
    @State private var status = "Model inventory has not been checked."
    @State private var loading = false

    var body: some View {
        Form {
            Section("Model provider") {
                Picker("Provider", selection: $modelProvider) {
                    Text("Cloudflare AI").tag("Cloudflare")
                    Text("Ollama (PC)").tag("Ollama")
                    Text("LM Studio (PC)").tag("LM Studio")
                }
                if modelProvider != "Cloudflare" {
                    TextField("HTTPS Tailscale model gateway URL", text: $localModelEndpoint)
                        .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    SecureField("API key (if required)", text: $localModelAPIKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model ID", text: $localModelID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { Task { await discoverModels() } } label: {
                        Label(loading ? "Checking models…" : "Scan PC model inventory", systemImage: "arrow.clockwise")
                    }.disabled(loading || localModelEndpoint.isEmpty)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                    if !availableModels.isEmpty {
                        Picker("Installed model", selection: $localModelID) {
                            ForEach(availableModels, id: \.self) { model in Text(model).tag(model) }
                        }
                    }
                } else {
                    Text("Cloudflare AI uses the configured GhostGPT Worker. Choose Ollama or LM Studio to use models hosted on your PC.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("PC model inventory (last checked)") {
                Text("Ollama models detected during setup: deepseek-r1:14b, qwen3.5:9b, qwen3:8b, qwen3:14b, gps-qwen3-fast-8b:latest, and gps-qwen3-fast:latest. LM Studio also advertises Meta Llama 3.1 8B Instruct, GPT-OSS 20B, Qwen 2.5 VL 7B, DeepSeek R1 Distill Qwen 7B, and Qwen 3.8 27B.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Recommended starting point: DeepSeek R1 14B for reasoning; Qwen 3.5 9B when you want a lighter, potentially faster model. The app only connects to a local model after you configure a private HTTPS gateway.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Network security") {
                Text("Use a private HTTPS endpoint reachable through Tailscale. Do not publish Ollama or LM Studio directly to the public internet. Model scanning runs only when you press the scan button.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("AI models")
    }

    private func discoverModels() async {
        let cleaned = localModelEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: cleaned), base.scheme == "https" else {
            status = "Enter a valid HTTPS Tailscale gateway URL."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let path = modelProvider == "Ollama" ? "api/tags" : "v1/models"
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.timeoutInterval = 12
            if !localModelAPIKey.isEmpty { request.setValue("Bearer \(localModelAPIKey)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "GhostGPT", code: 3, userInfo: [NSLocalizedDescriptionKey: "Model inventory endpoint did not return success."])
            }
            if modelProvider == "Ollama" {
                availableModels = try JSONDecoder().decode(OllamaTags.self, from: data).models.map(\.name).sorted()
            } else {
                availableModels = try JSONDecoder().decode(OpenAIModels.self, from: data).data.map(\.id).sorted()
            }
            if !availableModels.contains(localModelID), let first = availableModels.first { localModelID = first }
            status = "Found \(availableModels.count) model(s)."
        } catch {
            status = "Could not scan models: \(error.localizedDescription)"
        }
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @AppStorage("cloudflareEnabled") private var cloudflareEnabled = true
    @AppStorage("debugLogging") private var debugLogging = false
    var body: some View {
        Form {
            Section("AI service") {
                TextField("Service URL", text: $serviceURL).textInputAutocapitalization(.never).keyboardType(.URL)
                Toggle("Use Cloudflare edge connection", isOn: $cloudflareEnabled)
            }
            Section("Performance") {
                Text("Fast mode uses a shorter client timeout; Balanced and Deep allow longer responses. Actual model reasoning speed depends on the connected AI service.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Toggle("Debug logging", isOn: $debugLogging)
                Button("Reset connection settings", role: .destructive) {
                    serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
                    cloudflareEnabled = true
                    debugLogging = false
                }
            }
            Section("Security") {
                Text("Keep API keys, passwords, and private tokens on a protected server. Do not expose raw shell services to the public internet.")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("Advanced Settings")
    }
}
