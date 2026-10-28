import UIKit
import SwiftUI
import WebKit
import Security

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

enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "GhostGPT"

    private static func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    static func load(_ key: String) -> String? {
        var request = query(for: key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        let itemQuery = query(for: key)
        if value.isEmpty {
            let status = SecItemDelete(itemQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addQuery = itemQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func migratedValue(for key: String) -> String {
        if let secureValue = load(key), !secureValue.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return secureValue
        }
        let legacyValue = UserDefaults.standard.string(forKey: key) ?? ""
        guard !legacyValue.isEmpty else { return load(key) ?? "" }
        if save(legacyValue, for: key) { UserDefaults.standard.removeObject(forKey: key) }
        return legacyValue
    }
}


enum ModelProvider: String, CaseIterable, Identifiable {
    case cloudflare = "Cloudflare"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    var id: String { rawValue }
    var keychainAccount: String { self == .cloudflare ? "cloudflareAPIKey" : "localModelAPIKey" }
}

enum LocalModelClient {
    private static let defaultCloudflareEndpoint = "https://ghostgpt-ai.conman31115.workers.dev"

    static func validatedBaseURL(_ endpoint: String, provider: ModelProvider) throws -> URL {
        let cleaned = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: cleaned),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw NSError(domain: "GhostGPT.ModelProvider", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(provider.rawValue) requires an HTTPS endpoint without embedded credentials, query parameters, or fragments."
            ])
        }
        return url
    }

    private static func addBearer(_ token: String, to request: inout URLRequest) {
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    private static func updateSelectedModel(_ model: String, provider: ModelProvider) {
        let defaults = UserDefaults.standard
        switch provider {
        case .cloudflare: defaults.set(model, forKey: "cloudflareModelID")
        case .ollama: defaults.set(model, forKey: "ollamaModelID")
        case .lmStudio: defaults.set(model, forKey: "lmStudioModelID")
        }
        defaults.set(model, forKey: "localModelID")
    }

    static func chat(
        provider providerName: String? = nil,
        endpoint: String,
        model: String,
        messages: [[String: String]],
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        let selectedProvider = ModelProvider(
            rawValue: providerName ?? UserDefaults.standard.string(forKey: "modelProvider") ?? ModelProvider.lmStudio.rawValue
        ) ?? .lmStudio
        let configuredEndpoint = selectedProvider == .cloudflare
            ? (UserDefaults.standard.string(forKey: "serviceURL") ?? defaultCloudflareEndpoint)
            : endpoint
        let base = try validatedBaseURL(configuredEndpoint, provider: selectedProvider)
        let apiKey = KeychainStore.migratedValue(for: selectedProvider.keychainAccount)
        if selectedProvider != .cloudflare && apiKey.isEmpty {
            throw NSError(domain: "GhostGPT.ModelProvider", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "The PC gateway bearer token is required for \(selectedProvider.rawValue). Enter it in Settings → AI models."
            ])
        }
        let selectedModelInput = model.trimmingCharacters(in: .whitespacesAndNewlines)

        switch selectedProvider {
        case .cloudflare:
            let userMessage = messages.last(where: { $0["role"] == "user" })?["content"] ?? ""
            guard !userMessage.isEmpty else {
                throw NSError(domain: "GhostGPT.Cloudflare", code: 2, userInfo: [NSLocalizedDescriptionKey: "No user message was supplied to the Cloudflare provider."])
            }
            var request = URLRequest(url: base.appendingPathComponent("chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            addBearer(apiKey, to: &request)
            request.timeoutInterval = timeout
            var payload: [String: Any] = [
                "message": userMessage, "messages": messages,
                "speed": UserDefaults.standard.string(forKey: "speedMode")?.lowercased() ?? "balanced",
                "tools": []
            ]
            if !selectedModelInput.isEmpty { payload["model"] = selectedModelInput }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let providerError = try? JSONDecoder().decode(AIError.self, from: data)
                throw NSError(domain: "GhostGPT.Cloudflare", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Cloudflare returned HTTP \(http.statusCode). \(providerError?.error ?? String(detail.prefix(1000)))"
                ])
            }
            let reply: String
            if let decoded = try? JSONDecoder().decode(AIReply.self, from: data) {
                reply = decoded.reply
            } else if let decoded = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data) {
                reply = decoded.choices.first?.message.content ?? ""
            } else {
                throw NSError(domain: "GhostGPT.Cloudflare", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Cloudflare returned an unsupported response. The /chat endpoint must return a reply field or an OpenAI-compatible chat response."
                ])
            }
            let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw NSError(domain: "GhostGPT.Cloudflare", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cloudflare returned an empty reply."]) }
            return cleaned

        case .ollama:
            var inventoryRequest = URLRequest(url: base.appendingPathComponent("api/tags"))
            inventoryRequest.timeoutInterval = min(timeout, 15)
            addBearer(apiKey, to: &inventoryRequest)
            let (inventoryData, inventoryResponse) = try await URLSession.shared.data(for: inventoryRequest)
            guard let inventoryHTTP = inventoryResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(inventoryHTTP.statusCode) else {
                let detail = String(data: inventoryData, encoding: .utf8) ?? ""
                throw NSError(domain: "GhostGPT.Ollama", code: inventoryHTTP.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Ollama model inventory returned HTTP \(inventoryHTTP.statusCode). Check the authenticated gateway and Ollama readiness. \(String(detail.prefix(800)))"
                ])
            }
            let modelIDs = try JSONDecoder().decode(OllamaTags.self, from: inventoryData).models.map(\.name).sorted()
            guard !modelIDs.isEmpty else {
                throw NSError(domain: "GhostGPT.Ollama", code: 5, userInfo: [NSLocalizedDescriptionKey: "Ollama is reachable but advertises no models. Pull or load a model, then scan again."])
            }
            let selectedModel = modelIDs.contains(selectedModelInput) ? selectedModelInput : modelIDs[0]
            if selectedModel != selectedModelInput { updateSelectedModel(selectedModel, provider: .ollama) }
            var request = URLRequest(url: base.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            addBearer(apiKey, to: &request)
            request.timeoutInterval = timeout
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": selectedModel, "stream": false, "think": false, "messages": messages,
                "options": ["num_predict": maxTokens, "num_ctx": 4096]
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "GhostGPT.Ollama", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Ollama chat returned HTTP \(http.statusCode). \(String(detail.prefix(1000)))"
                ])
            }
            let reply = try JSONDecoder().decode(OllamaChatResponse.self, from: data).message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { throw NSError(domain: "GhostGPT.Ollama", code: 6, userInfo: [NSLocalizedDescriptionKey: "Ollama returned an empty reply."]) }
            return reply

        case .lmStudio:
            var startRequest = URLRequest(url: base.appendingPathComponent("control/start"))
            startRequest.httpMethod = "POST"
            startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            addBearer(apiKey, to: &startRequest)
            startRequest.httpBody = Data("{}".utf8)
            startRequest.timeoutInterval = min(max(timeout, 30), 90)
            let (startData, startResponse) = try await URLSession.shared.data(for: startRequest)
            guard let startHTTP = startResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(startHTTP.statusCode) else {
                let detail = String(data: startData, encoding: .utf8) ?? ""
                throw NSError(domain: "GhostGPT.LMStudio", code: startHTTP.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "LM Studio gateway startup failed (HTTP \(startHTTP.statusCode)). Check the gateway token and PC model-server readiness. \(String(detail.prefix(800)))"
                ])
            }
            let inventory = (try? JSONSerialization.jsonObject(with: startData)) as? [String: Any]
            var modelIDs = inventory?["models"] as? [String] ?? []
            if modelIDs.isEmpty {
                var modelsRequest = URLRequest(url: base.appendingPathComponent("v1/models"))
                addBearer(apiKey, to: &modelsRequest)
                modelsRequest.timeoutInterval = min(timeout, 15)
                let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
                guard let modelsHTTP = modelsResponse as? HTTPURLResponse, (200..<300).contains(modelsHTTP.statusCode) else {
                    throw NSError(domain: "GhostGPT.LMStudio", code: 7, userInfo: [NSLocalizedDescriptionKey: "LM Studio started but its /v1/models inventory could not be read."])
                }
                modelIDs = try JSONDecoder().decode(OpenAIModels.self, from: modelsData).data.map(\.id)
            }
            modelIDs = Array(Set(modelIDs.filter { !$0.isEmpty })).sorted()
            guard !modelIDs.isEmpty else {
                throw NSError(domain: "GhostGPT.LMStudio", code: 8, userInfo: [NSLocalizedDescriptionKey: "The PC gateway is reachable but reports no LM Studio models."])
            }
            let selectedModel: String
            if modelIDs.contains(selectedModelInput) { selectedModel = selectedModelInput }
            else if modelIDs.contains("openai/gpt-oss-20b") { selectedModel = "openai/gpt-oss-20b" }
            else { selectedModel = modelIDs[0] }
            if selectedModel != selectedModelInput { updateSelectedModel(selectedModel, provider: .lmStudio) }
            var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            addBearer(apiKey, to: &request)
            request.timeoutInterval = timeout
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": selectedModel, "stream": false, "messages": messages, "max_tokens": maxTokens
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "GhostGPT.LMStudio", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "LM Studio returned HTTP \(http.statusCode). \(String(detail.prefix(1000)))"
                ])
            }
            let reply = (try JSONDecoder().decode(OpenAIChatResponse.self, from: data)).choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reply.isEmpty else { throw NSError(domain: "GhostGPT.LMStudio", code: 9, userInfo: [NSLocalizedDescriptionKey: "LM Studio returned an empty response."]) }
            return reply
        }
    }
}
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
    @AppStorage("speedMode") private var speedMode = "Balanced"
    @AppStorage("modelProvider") private var modelProvider = "LM Studio"
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @AppStorage("localModelEndpoint") private var localModelEndpoint = "https://msi.tail28f016.ts.net:10000"
    @AppStorage("localModelID") private var localModelID = "openai/gpt-oss-20b"
    @AppStorage("cloudflareModelID") private var cloudflareModelID = ""
    @AppStorage("ollamaModelID") private var ollamaModelID = "gps-qwen3-fast-8b:latest"
    @AppStorage("lmStudioModelID") private var lmStudioModelID = "openai/gpt-oss-20b"
    @AppStorage("autoStartPCModel") private var autoStartPCModel = true
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
    @State private var attemptedAutoStart = false
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
                    Picker("AI provider", selection: $modelProvider) {
                        ForEach(ModelProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider.rawValue)
                        }
                    }
                    Text("Active provider: (modelProvider)").font(.subheadline)
                    Text("Cloudflare uses its configured HTTPS Worker; Ollama and LM Studio use the authenticated private PC gateway.").font(.footnote).foregroundStyle(.secondary)
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
                    if messages.last?.isUser == true {
                        Button("Retry") { retryLastMessage() }
                            .font(.caption.weight(.semibold))
                    }
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
        .onAppear {
            guard modelProvider == ModelProvider.lmStudio.rawValue, autoStartPCModel, !attemptedAutoStart else { return }
            attemptedAutoStart = true
            Task { await startPCModelOnAppOpen() }
        }
        .onChange(of: modelProvider) { oldValue, newValue in
            saveModel(localModelID, for: oldValue)
            localModelID = modelForProvider(newValue)
            attemptedAutoStart = false
            if newValue == ModelProvider.lmStudio.rawValue, autoStartPCModel {
                attemptedAutoStart = true
                Task { await startPCModelOnAppOpen() }
            }
        }
        .onChange(of: localModelID) { _, value in saveModel(value, for: modelProvider) }
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
                },
                onDelete: { id in deleteSavedChat(id) },
                onClear: { savedChatsJSON = "[]" }
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

    private func modelForProvider(_ name: String) -> String {
        switch ModelProvider(rawValue: name) ?? .lmStudio {
        case .cloudflare: return cloudflareModelID
        case .ollama: return ollamaModelID
        case .lmStudio: return lmStudioModelID
        }
    }

    private func saveModel(_ value: String, for name: String) {
        switch ModelProvider(rawValue: name) ?? .lmStudio {
        case .cloudflare: cloudflareModelID = value
        case .ollama: ollamaModelID = value
        case .lmStudio: lmStudioModelID = value
        }
    }

    private func deleteSavedChat(_ id: UUID) {
        guard let data = savedChatsJSON.data(using: .utf8) else { return }
        var sessions = (try? JSONDecoder().decode([ChatSession].self, from: data)) ?? []
        sessions.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(sessions) {
            savedChatsJSON = String(data: encoded, encoding: .utf8) ?? "[]"
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
                // Bound request size so long conversations do not overwhelm the phone or model gateway.
                let history = messages.suffix(24).map {
                    ["role": $0.isUser ? "user" : "assistant", "content": String($0.text.prefix(12000))]
                }
                try await sendToLocalModel(history: history)
            } catch {
                errorText = error.localizedDescription == "The operation couldn’t be completed. (NSURLErrorDomain error -1009.)"
                    ? "No internet connection. Reconnect and try again."
                    : "GhostGPT request failed: \(error.localizedDescription)"
            }
        }
    }

    private func retryLastMessage() {
        guard !isConnecting, let last = messages.last, last.isUser else { return }
        draft = last.text
        messages.removeLast()
        errorText = nil
        composerFocused = true
    }

    private func startPCModelOnAppOpen() async {
        guard modelProvider == ModelProvider.lmStudio.rawValue else { return }
        let cleaned = localModelEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: cleaned), base.scheme == "https" else { return }
        do {
            try await ensurePCModelReady(base: base)
        } catch {
            errorText = "PC-only LM Studio startup failed: \(error.localizedDescription)"
        }
    }

    private func ensurePCModelReady(base: URL) async throws {
        let apiKey = KeychainStore.migratedValue(for: "localModelAPIKey")
        var startRequest = URLRequest(url: base.appendingPathComponent("control/start"))
        startRequest.httpMethod = "POST"
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { startRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        startRequest.timeoutInterval = 90
        startRequest.httpBody = Data("{}".utf8)
        let (startData, startResponse) = try await URLSession.shared.data(for: startRequest)
        guard let startHTTP = startResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(startHTTP.statusCode) else {
            let detail = String(data: startData, encoding: .utf8) ?? "No gateway details were returned."
            throw NSError(domain: "GhostGPT.PCModel", code: startHTTP.statusCode, userInfo: [NSLocalizedDescriptionKey: "The PC model service did not start (HTTP \(startHTTP.statusCode)): \(String(detail.prefix(500)))"])
        }

        var modelsRequest = URLRequest(url: base.appendingPathComponent("v1/models"))
        if !apiKey.isEmpty { modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        modelsRequest.timeoutInterval = 15
        let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
        guard let modelsHTTP = modelsResponse as? HTTPURLResponse,
              (200..<300).contains(modelsHTTP.statusCode) else {
            throw NSError(domain: "GhostGPT.PCModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "The PC gateway started, but its LM Studio model inventory could not be read."])
        }
        let modelIDs = try JSONDecoder().decode(OpenAIModels.self, from: modelsData).data.map(\.id)
        guard !modelIDs.isEmpty else {
            throw NSError(domain: "GhostGPT.PCModel", code: 3, userInfo: [NSLocalizedDescriptionKey: "LM Studio is running on the PC but advertises no models. Download or enable a model in LM Studio, then retry."])
        }
        if !modelIDs.contains(localModelID) {
            localModelID = modelIDs.contains("openai/gpt-oss-20b") ? "openai/gpt-oss-20b" : (modelIDs.sorted().first ?? modelIDs[0])
        }
    }

    private func sendToLocalModel(history: [[String: String]]) async throws {
        let reply = try await LocalModelClient.chat(
            provider: modelProvider,
            endpoint: localModelEndpoint,
            model: localModelID,
            messages: history,
            maxTokens: speedMode == "Fast" ? 128 : 512,
            timeout: speedMode == "Fast" ? 45 : 180
        )
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
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var browserLoading = false
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
            EmbeddedBrowser(
                urlString: currentURL,
                reloadToken: reloadToken,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $browserLoading
            )
            if browserLoading { ProgressView().progressViewStyle(.linear).padding(.horizontal, 12) }
            HStack(spacing: 18) {
                Button { NotificationCenter.default.post(name: .ghostBrowserBack, object: nil) } label: {
                    Image(systemName: "chevron.left")
                }.disabled(!canGoBack).accessibilityLabel("Go back")
                Button { NotificationCenter.default.post(name: .ghostBrowserForward, object: nil) } label: {
                    Image(systemName: "chevron.right")
                }.disabled(!canGoForward).accessibilityLabel("Go forward")
                Spacer()
                Button { reloadToken = UUID() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                Spacer()
                Button { address = "https://www.google.com"; navigate() } label: { Label("Home", systemImage: "house") }
                Button { UIPasteboard.general.string = currentURL } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy URL")
            }.font(.caption).padding(12).background(.ultraThinMaterial)
        }
        .navigationTitle("Ghost Browser").navigationBarTitleDisplayMode(.inline)
    }
    private func navigate() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains(where: { $0.isWhitespace }) || (!trimmed.contains(".") && !trimmed.contains("://")) {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            guard let url = components?.url else { return }
            currentURL = url.absoluteString
        } else {
            let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let url = URL(string: candidate),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else {
                address = "Invalid URL — use a website address or search terms"
                addressFocused = true
                return
            }
            currentURL = url.absoluteString
            address = url.absoluteString
        }
        addressFocused = false
    }
}

extension Notification.Name {
    static let ghostBrowserBack = Notification.Name("GhostGPTBrowserBack")
    static let ghostBrowserForward = Notification.Name("GhostGPTBrowserForward")
}

struct EmbeddedBrowser: UIViewRepresentable {
    let urlString: String
    let reloadToken: UUID
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.observeNavigationButtons()
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastURL != urlString, let url = URL(string: urlString) {
            context.coordinator.lastURL = urlString
            webView.load(URLRequest(url: url))
        }
        if context.coordinator.lastReload != reloadToken {
            context.coordinator.lastReload = reloadToken
            if context.coordinator.lastURL == urlString { webView.reload() }
        }
        context.coordinator.refreshState()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EmbeddedBrowser
        weak var webView: WKWebView?
        var lastURL = ""
        var lastReload = UUID()
        private var backObserver: NSObjectProtocol?
        private var forwardObserver: NSObjectProtocol?

        init(parent: EmbeddedBrowser) { self.parent = parent }

        func observeNavigationButtons() {
            backObserver = NotificationCenter.default.addObserver(forName: .ghostBrowserBack, object: nil, queue: .main) { [weak self] _ in
                guard let self, let webView = self.webView, webView.canGoBack else { return }
                webView.goBack()
            }
            forwardObserver = NotificationCenter.default.addObserver(forName: .ghostBrowserForward, object: nil, queue: .main) { [weak self] _ in
                guard let self, let webView = self.webView, webView.canGoForward else { return }
                webView.goForward()
            }
        }

        func refreshState() {
            guard let webView else { return }
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.isLoading = webView.isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            refreshState()
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            refreshState()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            refreshState()
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            refreshState()
        }
        deinit {
            if let backObserver { NotificationCenter.default.removeObserver(backObserver) }
            if let forwardObserver { NotificationCenter.default.removeObserver(forwardObserver) }
        }
    }
}

struct ToolsView: View {
    var body: some View {
        List {
            Section("Agent workspace") {
                NavigationLink { AgentWorkspaceView() } label: { Label("AI agent loop (PowerShell)", systemImage: "sparkles") }
            }
            Section("Built-in tools") {
                NavigationLink { BrowserView() } label: { Label("Ghost Browser", systemImage: "globe") }
                NavigationLink { TerminalGatewayView(mode: "powershell") } label: { Label("PowerShell terminal", systemImage: "terminal") }
                NavigationLink { TerminalGatewayView(mode: "ssh") } label: { Label("Linux sandbox / SSH", systemImage: "server.rack") }
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
    @AppStorage("localModelEndpoint") private var localModelEndpoint = "https://msi.tail28f016.ts.net:10000"
    @AppStorage("localModelID") private var localModelID = "openai/gpt-oss-20b"
    @State private var host = ""
    @State private var username = ""
    @State private var command = ""
    @State private var taskDescription = ""
    @State private var output = "Connect a trusted terminal gateway in Settings to execute commands. No command has been run."
    @State private var running = false
    @State private var drafting = false
    @AppStorage("speedMode") private var speedMode = "Balanced"
    @State private var showingSettings = false
    @State private var showingRiskConfirmation = false
    @State private var checkingGateway = false
    @State private var gatewayStatus = "Not checked yet."
    private var manualCommandIsRisky: Bool {
        let lowered = command.lowercased()
        let markers = [
            "set-", "new-", "remove-", "add-", "clear-", "format-", "restart-",
            "stop-", "start-", "enable-", "disable-", "move-item", "copy-item",
            "rename-item", "out-file", "set-content", "add-content", "reg add",
            "reg delete", "net user", "sc config", "shutdown", "taskkill",
            "install-", "uninstall-", "invoke-expression", "iex ", "-encodedcommand"
        ]
        return markers.contains { lowered.contains($0) }
    }

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
                    Button {
                        if manualCommandIsRisky {
                            showingRiskConfirmation = true
                        } else {
                            Task { await execute(riskConfirmed: false) }
                        }
                    } label: {
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
                Button {
                    Task { await checkGatewayConnection() }
                } label: {
                    Label(checkingGateway ? "Checking connection…" : "Test gateway connection", systemImage: "network")
                }.buttonStyle(.bordered).disabled(checkingGateway)
                Text(gatewayStatus).font(.caption).foregroundStyle(.secondary)
                Text("The authenticated HEAD check reports whether PowerShell is available. It never runs a command.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Security: only use a gateway you trust. Review commands before running them. Credentials should be handled by the gateway, not pasted into chat.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding()
            .navigationTitle(mode == "ssh" ? "SSH" : "PowerShell")
            .onAppear {
                if host.isEmpty { host = mode == "ssh" ? "Ghost" : "msi" }
                if gatewayStatus == "Not checked yet." && !gatewayURL.isEmpty {
                    Task { await checkGatewayConnection() }
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { TerminalGatewaySettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } } } }
            }
            .confirmationDialog("Run a potentially risky terminal command?", isPresented: $showingRiskConfirmation, titleVisibility: .visible) {
                Button("Run risky command", role: .destructive) { Task { await execute(riskConfirmed: true) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The command may modify the PC. Review it carefully before confirming.")
            }
    }

    @MainActor
    private func checkGatewayConnection() async {
        let cleaned = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned), url.scheme == "https", url.host != nil else {
            gatewayStatus = "Configure a valid HTTPS gateway URL in Settings."
            return
        }
        checkingGateway = true
        defer { checkingGateway = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 8
            let token = KeychainStore.migratedValue(for: "terminalGatewayToken")
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            switch http.statusCode {
            case 200..<300:
                gatewayStatus = "Authenticated gateway is reachable and PowerShell is available (HTTP \(http.statusCode)). No command was run."
            case 401, 403:
                gatewayStatus = "Gateway is reachable but rejected authentication (HTTP \(http.statusCode)). Check the bearer token in Settings."
            case 404:
                gatewayStatus = "Gateway host is reachable, but this endpoint path returned HTTP 404. Check the configured URL."
            case 405:
                gatewayStatus = "Gateway is reachable, but HEAD health checks are unsupported (HTTP 405). A dedicated health endpoint is needed to confirm readiness."
            case 503:
                gatewayStatus = "Gateway is reachable and authenticated, but PowerShell is unavailable or not ready. Check Windows PowerShell and the gateway startup log."
            case 500..<600:
                gatewayStatus = "Gateway responded with HTTP \(http.statusCode). The service or its upstream may not be ready."
            default:
                gatewayStatus = "Gateway responded with HTTP \(http.statusCode). No command was sent."
            }
        } catch {
            gatewayStatus = "Could not reach the HTTPS gateway: \(error.localizedDescription). No command was sent."
        }
    }

    private func draftCommand() async {
        let task = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        drafting = true
        defer { drafting = false }
        do {
            let shell = mode == "ssh" ? "Linux POSIX shell over SSH" : "Windows PowerShell"
            let instruction = "Draft exactly one \(shell) command for this task: \(task). Return only the command, no Markdown fences or explanation. Prefer read-only inspection. Do not use destructive commands, change security settings, delete files, or expose credentials."
            let drafted = try await LocalModelClient.chat(
                endpoint: localModelEndpoint,
                model: localModelID,
                messages: [
                    ["role": "system", "content": "Draft commands only. Never claim to execute a command. Prefer read-only inspection and do not include destructive operations or credential access."],
                    ["role": "user", "content": instruction]
                ],
                maxTokens: 160,
                timeout: speedMode == "Fast" ? 25 : 75
            )
            command = drafted.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            output += "\n\nLocal model command draft failed: \(error.localizedDescription)"
        }
    }

    private func execute(riskConfirmed: Bool = false) async {
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
            let gatewayToken = KeychainStore.migratedValue(for: "terminalGatewayToken")
            if !gatewayToken.isEmpty { request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization") }
            request.timeoutInterval = 65
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "mode": mode, "host": host, "username": username, "command": submitted,
                "approved": true, "riskConfirmed": riskConfirmed
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
    @State private var gatewayToken = KeychainStore.migratedValue(for: "terminalGatewayToken")
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
            .onChange(of: gatewayToken) { value in _ = KeychainStore.save(value, for: "terminalGatewayToken") }
    }
}

struct ChatHistorySheet: View {
    let savedChatsJSON: String
    let onNewChat: () -> Void
    let onSelect: (ChatSession) -> Void
    let onDelete: (UUID) -> Void
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var confirmingClear = false

    private var sessions: [ChatSession] {
        guard let data = savedChatsJSON.data(using: .utf8) else { return [] }
        let all = (try? JSONDecoder().decode([ChatSession].self, from: data)) ?? []
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.messages.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: onNewChat) { Label("New chat", systemImage: "square.and.pencil") }
                    if !sessions.isEmpty {
                        Button {
                            UIPasteboard.general.string = savedChatsJSON
                        } label: {
                            Label("Copy chat backup (JSON)", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) { confirmingClear = true } label: {
                            Label("Clear all saved chats", systemImage: "trash")
                        }
                    }
                }
                Section("Saved conversations") {
                    if sessions.isEmpty {
                        Text(searchText.isEmpty ? "Your conversations will appear here automatically." : "No conversations match your search.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(sessions) { session in
                            Button { onSelect(session) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.title).font(.body).lineLimit(2)
                                    Text("\(session.messages.count) messages · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { onDelete(session.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search chats and messages")
            .navigationTitle("Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete all saved conversations?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete all chats", role: .destructive) { onClear() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently removes the locally saved chat list from this device.")
            }
        }.presentationDetents([.medium, .large])
    }
}


struct MCPConnectorView: View {
    @AppStorage("mcpServerURL") private var serverURL = ""
    @State private var bearerToken = KeychainStore.migratedValue(for: "mcpBearerToken")
    @State private var tools: [MCPToolInfo] = []
    @State private var selectedTool = ""
    @State private var argumentsJSON = "{}"
    @State private var resultText = "Connect to an MCP server to discover its tools."
    @State private var busy = false
    @State private var protocolVersion = "2025-03-26"
    @State private var sessionID: String?
    @State private var requestID = 10

    var body: some View {
        Form {
            Section("MCP server (Streamable HTTP)") {
                TextField("HTTPS MCP endpoint URL", text: $serverURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                SecureField("Bearer token (optional)", text: $bearerToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { Task { await connectAndListTools() } } label: {
                    Label(busy ? "Connecting…" : "Connect and discover tools", systemImage: "point.3.connected.trianglepath.dotted")
                }.disabled(busy || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Uses MCP JSON-RPC over Streamable HTTP. The server must be reachable from this iPhone, preferably through private Tailscale access.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Discovered tools (\(tools.count))") {
                if tools.isEmpty {
                    Text("No tools loaded yet. Connect to the endpoint first.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker("Tool", selection: $selectedTool) {
                        ForEach(tools) { tool in Text(tool.name).tag(tool.name) }
                    }
                    if let tool = tools.first(where: { $0.name == selectedTool }), !tool.description.isEmpty {
                        Text(tool.description).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Arguments JSON").font(.subheadline.weight(.medium))
                    TextEditor(text: $argumentsJSON).font(.system(.footnote, design: .monospaced)).frame(minHeight: 100)
                    Button { Task { await callSelectedTool() } } label: {
                        Label(busy ? "Working…" : "Call selected MCP tool", systemImage: "play.fill")
                    }.disabled(busy || selectedTool.isEmpty)
                    Text("Review arguments before execution. Tools can modify systems or data according to the server's permissions.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("Connection output") {
                Text(resultText).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
        }
        .navigationTitle("MCP connectors")
            .onChange(of: bearerToken) { value in _ = KeychainStore.save(value, for: "mcpBearerToken") }
    }

    private func nextRequestID() -> Int {
        requestID += 1
        return requestID
    }

    private func makeRequest(method: String, params: [String: Any], id: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else {
            throw NSError(domain: "GhostGPT.MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid HTTPS MCP endpoint."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if let returnedSession = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !returnedSession.isEmpty {
            sessionID = returnedSession
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GhostGPT.MCP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "MCP HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "No response body")"])
        }
        return (data, http)
    }

    private func sendInitializedNotification() async throws {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else {
            throw NSError(domain: "GhostGPT.MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid HTTPS MCP endpoint."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized", "params": [:] as [String: Any]
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GhostGPT.MCP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "MCP initialized notification returned HTTP \(http.statusCode)."])
        }
    }

    private func decodeJSONRPC(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        if let text = String(data: data, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let bytes = payload.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { return object }
            }
        }
        throw NSError(domain: "GhostGPT.MCP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Server response was not a supported JSON-RPC response."])
    }

    private func connectAndListTools() async {
        busy = true
        defer { busy = false }
        sessionID = nil
        tools = []
        do {
            let (initData, _) = try await makeRequest(method: "initialize", params: [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "GhostGPT iOS", "version": "1.1"]
            ], id: nextRequestID())
            let initObject = try decodeJSONRPC(initData)
            if let error = initObject["error"] {
                throw NSError(domain: "GhostGPT.MCP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Initialize failed: \(error)"])
            }
            if let result = initObject["result"] as? [String: Any],
               let version = result["protocolVersion"] as? String { protocolVersion = version }
            try await sendInitializedNotification()

            var cursor: String?
            var discovered: [MCPToolInfo] = []
            var pageCount = 0
            repeat {
                var params: [String: Any] = [:]
                if let cursor { params["cursor"] = cursor }
                let (data, _) = try await makeRequest(method: "tools/list", params: params, id: nextRequestID())
                let object = try decodeJSONRPC(data)
                if let error = object["error"] {
                    throw NSError(domain: "GhostGPT.MCP", code: 4, userInfo: [NSLocalizedDescriptionKey: "tools/list failed: \(error)"])
                }
                let result = object["result"] as? [String: Any] ?? [:]
                let rawTools = result["tools"] as? [[String: Any]] ?? []
                discovered.append(contentsOf: rawTools.compactMap { item in
                    guard let name = item["name"] as? String else { return nil }
                    return MCPToolInfo(name: name, description: item["description"] as? String ?? "")
                })
                cursor = result["nextCursor"] as? String
                pageCount += 1
                if pageCount >= 100 && cursor != nil {
                    throw NSError(domain: "GhostGPT.MCP", code: 6, userInfo: [NSLocalizedDescriptionKey: "Tool listing exceeded 100 pages; stopped to prevent an endless pagination loop."])
                }
            } while cursor != nil
            tools = Dictionary(discovered.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            selectedTool = tools.first?.name ?? ""
            resultText = "Connected. Found \(tools.count) tool(s). Protocol: \(protocolVersion). Session: \(sessionID == nil ? "stateless" : "maintained")."
        } catch {
            tools = []
            resultText = "Connection failed: \(error.localizedDescription)"
        }
    }

    private func callSelectedTool() async {
        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
            resultText = "Arguments must be a valid JSON object. Example: provide the arguments required by the selected tool."
            return
        }
        guard let tool = tools.first(where: { $0.name == selectedTool }) else {
            resultText = "Select a discovered tool first."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let (data, _) = try await makeRequest(method: "tools/call", params: [
                "name": tool.name, "arguments": args
            ], id: nextRequestID())
            let object = try decodeJSONRPC(data)
            if let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                resultText = text
            } else { resultText = String(data: data, encoding: .utf8) ?? "Tool completed with an unreadable response." }
        } catch {
            resultText = "Tool call failed: \(error.localizedDescription)"
        }
    }
}

struct MCPToolInfo: Identifiable {
    let name: String
    let description: String
    var id: String { name }
}

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("speedMode") private var speedMode = "Balanced"
    var body: some View {
        List {
            Section("GhostGPT") {
                Label("Native SwiftUI interface", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("LM Studio on PC", systemImage: "desktopcomputer").foregroundStyle(.blue)
                Text("Main chat runs through the LM Studio-compatible API on your PC only. No cloud chat fallback is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preferences") {
                Picker("Response speed", selection: $speedMode) {
                    Text("Fast").tag("Fast"); Text("Balanced").tag("Balanced"); Text("Deep").tag("Deep")
                }
                Toggle("Notifications", isOn: $notificationsEnabled)
            }
            Section("Tools") {
                NavigationLink("PC model server (auto & manual)") { PCModelServerSettingsView() }
                NavigationLink("Plugins & capabilities") { PluginsView() }
                NavigationLink("AI models and local model scan") { LocalModelsSettingsView() }
                NavigationLink("Terminal gateway (PowerShell / Linux SSH)") { TerminalGatewaySettingsView() }
                NavigationLink("MCP connectors") { MCPConnectorView() }
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


struct PCModelServerSettingsView: View {
    @AppStorage("localModelEndpoint") private var localModelEndpoint = "https://msi.tail28f016.ts.net:10000"
    @AppStorage("autoStartPCModel") private var autoStartPCModel = true
    @AppStorage("localModelID") private var localModelID = "openai/gpt-oss-20b"
    @State private var localModelAPIKey = KeychainStore.migratedValue(for: "localModelAPIKey")
    @State private var busy = false
    @State private var status = "Checking the PC model server has not been run yet."

    var body: some View {
        Form {
            Section("LM Studio on your PC") {
                Label("PC-only model execution", systemImage: "desktopcomputer").font(.headline)
                Text("Chat inference runs on your Windows PC in LM Studio. The iPhone only sends requests to this private Tailscale endpoint; it does not host a model.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Start automatically when GhostGPT opens", isOn: $autoStartPCModel)
                TextField("Private HTTPS PC endpoint", text: $localModelEndpoint)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                SecureField("Gateway bearer token", text: $localModelAPIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Use the gateway token configured on the PC. It is stored in iOS Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Default model: \(localModelID)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Server controls") {
                Button {
                    Task { await startServerNow() }
                } label: {
                    Label(busy ? "Starting / checking…" : "Start PC model server now", systemImage: "power")
                }.disabled(busy)
                Button {
                    Task { await refreshStatus() }
                } label: {
                    Label("Check server status", systemImage: "checkmark.icloud")
                }.disabled(busy)
                Text(status).font(.footnote).textSelection(.enabled)
            }
            Section("Startup behavior") {
                Text("The PC has a Windows logon task to start LM Studio's local API and a separate local gateway. Opening GhostGPT checks the gateway and starts the API if it is stopped. The gateway listens only on the PC loopback interface and is published through the tailnet-only Tailscale endpoint.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("PC model server")
        .onAppear { Task { await refreshStatus() } }
        .onChange(of: localModelAPIKey) { _, value in _ = KeychainStore.save(value, for: "localModelAPIKey") }
    }

    private func endpoint() -> URL? {
        let cleaned = localModelEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: cleaned), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private func refreshStatus() async {
        guard let base = endpoint() else {
            status = "Enter the private HTTPS Tailscale URL for the PC model server."
            return
        }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: base.appendingPathComponent("control/status"))
            let apiKey = KeychainStore.migratedValue(for: "localModelAPIKey")
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (200..<300).contains(http.statusCode) {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let count = object["model_count"] as? Int ?? 0
                status = "PC model API is ready. \(count) model ID(s) found."
            } else {
                status = "PC model API is not ready (HTTP \(http.statusCode)). Press Start PC model server now to try to start it."
            }
        } catch {
            status = "PC model endpoint is unreachable: \(error.localizedDescription)"
        }
    }

    private func startServerNow() async {
        guard let base = endpoint() else {
            status = "Enter a valid private HTTPS Tailscale endpoint first."
            return
        }
        busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: base.appendingPathComponent("control/start"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let apiKey = KeychainStore.migratedValue(for: "localModelAPIKey")
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 90
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                status = "PC model start failed (HTTP \(http.statusCode)): \(String((String(data: data, encoding: .utf8) ?? "").prefix(500)))"
                return
            }
            let modelIDs = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [String] ?? []
            if !modelIDs.isEmpty && !modelIDs.contains(localModelID) {
                localModelID = modelIDs.contains("openai/gpt-oss-20b") ? "openai/gpt-oss-20b" : (modelIDs.sorted().first ?? modelIDs[0])
            }
            status = "Started / verified LM Studio on the PC. Found \(modelIDs.count) model ID(s). Active selection: \(localModelID)."
        } catch {
            status = "Could not start the PC model server: \(error.localizedDescription)"
        }
    }
}

struct LocalModelsSettingsView: View {
    @AppStorage("modelProvider") private var modelProvider = "LM Studio"
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @AppStorage("localModelEndpoint") private var localModelEndpoint = "https://msi.tail28f016.ts.net:10000"
    @AppStorage("localModelID") private var localModelID = "openai/gpt-oss-20b"
    @AppStorage("cloudflareModelID") private var cloudflareModelID = ""
    @AppStorage("ollamaModelID") private var ollamaModelID = "gps-qwen3-fast-8b:latest"
    @AppStorage("lmStudioModelID") private var lmStudioModelID = "openai/gpt-oss-20b"
    @State private var providerAPIKey = ""
    @State private var availableModels: [String] = []
    @State private var status = "Model inventory has not been checked."
    @State private var loading = false

    private var provider: ModelProvider { ModelProvider(rawValue: modelProvider) ?? .lmStudio }
    private var activeEndpoint: Binding<String> {
        Binding(get: { provider == .cloudflare ? serviceURL : localModelEndpoint },
                set: { value in if provider == .cloudflare { serviceURL = value } else { localModelEndpoint = value } })
    }

    var body: some View {
        Form {
            Section("Model provider") {
                Picker("Provider", selection: $modelProvider) {
                    ForEach(ModelProvider.allCases) { item in Text(item.rawValue).tag(item.rawValue) }
                }
                TextField(provider == .cloudflare ? "Cloudflare Worker HTTPS URL" : "Private HTTPS Tailscale gateway URL", text: activeEndpoint)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                SecureField(provider == .cloudflare ? "Cloudflare bearer token (optional)" : "PC gateway bearer token", text: $providerAPIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Active model ID (optional for Cloudflare)", text: $localModelID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { Task { await discoverModels() } } label: {
                    Label(loading ? "Scanning models…" : "Scan provider model inventory", systemImage: "arrow.clockwise")
                }.disabled(loading || activeEndpoint.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                if !availableModels.isEmpty {
                    Picker("Available model", selection: $localModelID) {
                        ForEach(availableModels, id: \.self) { model in Text(model).tag(model) }
                    }
                }
            }
            Section("Provider behavior") {
                switch provider {
                case .cloudflare:
                    Text("Chat and agent planning use the HTTPS Worker /chat route. Inventory scanning expects the Worker to expose /v1/models; if it does not, enter a model ID manually or configure that route on the Worker.")
                case .ollama:
                    Text("Ollama model scanning uses /api/tags and chat uses /api/chat through the authenticated PC gateway. The gateway must be configured to reach Ollama on loopback port 11434.")
                case .lmStudio:
                    Text("LM Studio startup and inventory use the authenticated PC gateway /control/start and /v1/models routes. A saved model ID is replaced only when it is no longer advertised.")
                }
            }
            Section("Remote access security") {
                Text("All configured endpoints must use HTTPS. Keep Ollama and LM Studio on loopback behind Tailscale Serve and bearer authentication; do not expose raw model APIs to the public internet. Cloudflare credentials and PC gateway tokens are stored separately in iOS Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI models")
        .onAppear { providerAPIKey = KeychainStore.migratedValue(for: provider.keychainAccount) }
        .onChange(of: modelProvider) { oldValue, newValue in
            saveModel(localModelID, for: oldValue)
            localModelID = modelForProvider(newValue)
            providerAPIKey = KeychainStore.migratedValue(for: (ModelProvider(rawValue: newValue) ?? .lmStudio).keychainAccount)
            availableModels = []
            status = "Provider changed. Scan the new provider before relying on its model inventory."
        }
        .onChange(of: providerAPIKey) { _, value in _ = KeychainStore.save(value, for: provider.keychainAccount) }
        .onChange(of: localModelID) { _, value in saveModel(value, for: modelProvider) }
    }

    private func modelForProvider(_ name: String) -> String {
        switch ModelProvider(rawValue: name) ?? .lmStudio {
        case .cloudflare: return cloudflareModelID
        case .ollama: return ollamaModelID
        case .lmStudio: return lmStudioModelID
        }
    }

    private func saveModel(_ value: String, for name: String) {
        switch ModelProvider(rawValue: name) ?? .lmStudio {
        case .cloudflare: cloudflareModelID = value
        case .ollama: ollamaModelID = value
        case .lmStudio: lmStudioModelID = value
        }
    }

    private func discoverModels() async {
        guard let base = try? LocalModelClient.validatedBaseURL(activeEndpoint.wrappedValue, provider: provider) else {
            status = "\(provider.rawValue) requires a valid HTTPS endpoint without embedded credentials."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let token = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if provider != .cloudflare && token.isEmpty {
                throw NSError(domain: "GhostGPT.ModelScan", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "The PC gateway bearer token is required to scan (provider.rawValue) models."
                ])
            }
            if !token.isEmpty { _ = KeychainStore.save(token, for: provider.keychainAccount) }
            var modelIDs: [String] = []
            if provider == .lmStudio {
                var startRequest = URLRequest(url: base.appendingPathComponent("control/start"))
                startRequest.httpMethod = "POST"
                startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !token.isEmpty { startRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                startRequest.httpBody = Data("{}".utf8)
                startRequest.timeoutInterval = 90
                let (startData, startResponse) = try await URLSession.shared.data(for: startRequest)
                guard let startHTTP = startResponse as? HTTPURLResponse, (200..<300).contains(startHTTP.statusCode) else {
                    let code = (startResponse as? HTTPURLResponse)?.statusCode ?? -1
                    let body = String(data: startData, encoding: .utf8) ?? ""
                    throw NSError(domain: "GhostGPT.ModelScan", code: code, userInfo: [NSLocalizedDescriptionKey: "LM Studio gateway startup failed. \(String(body.prefix(800)))"])
                }
                modelIDs = ((try? JSONSerialization.jsonObject(with: startData)) as? [String: Any])?["models"] as? [String] ?? []
            } else {
                let path = provider == .ollama ? "api/tags" : "v1/models"
                var request = URLRequest(url: base.appendingPathComponent(path))
                request.timeoutInterval = 15
                if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "GhostGPT.ModelScan", code: code, userInfo: [NSLocalizedDescriptionKey: "\(provider.rawValue) inventory returned HTTP \(code). \(String(body.prefix(800)))"])
                }
                if provider == .ollama { modelIDs = try JSONDecoder().decode(OllamaTags.self, from: data).models.map(\.name) }
                else { modelIDs = try JSONDecoder().decode(OpenAIModels.self, from: data).data.map(\.id) }
            }
            availableModels = Array(Set(modelIDs.filter { !$0.isEmpty })).sorted()
            guard !availableModels.isEmpty else {
                throw NSError(domain: "GhostGPT.ModelScan", code: 10, userInfo: [NSLocalizedDescriptionKey: "\(provider.rawValue) is reachable but reports no models."])
            }
            if !availableModels.contains(localModelID) {
                localModelID = availableModels.contains("openai/gpt-oss-20b") ? "openai/gpt-oss-20b" : availableModels[0]
            }
            status = "Found \(availableModels.count) model(s) for \(provider.rawValue)."
        } catch {
            availableModels = []
            status = "Could not scan \(provider.rawValue) models: \(error.localizedDescription)"
        }
    }
}
struct AgentWorkspaceView: View {
    @AppStorage("terminalGatewayURL") private var gatewayURL = "https://msi.tail28f016.ts.net:10000/terminal"
    @AppStorage("localModelEndpoint") private var localModelEndpoint = "https://msi.tail28f016.ts.net:10000"
    @AppStorage("localModelID") private var localModelID = "openai/gpt-oss-20b"
    @State private var goal = ""
    @State private var plan = ""
    @State private var status = "Ready"
    @State private var busy = false
    @State private var preparingStep = false
    @State private var executingStep = false
    @State private var showingRiskConfirmation = false
    @AppStorage("agentSavedGoal") private var savedGoal = ""
    @AppStorage("agentSavedPlan") private var savedPlan = ""
    @AppStorage("agentSavedStatus") private var savedStatus = "Ready"
    @AppStorage("agentSavedLogJSON") private var savedLogJSON = "[]"
    @AppStorage("agentPendingCommand") private var proposedCommand = ""
    @AppStorage("agentPendingPurpose") private var proposalPurpose = ""
    @AppStorage("agentPendingRisk") private var proposalRisk = "read-only"
    @AppStorage("agentPendingExpectedResult") private var expectedResult = ""
    @AppStorage("agentRemoteHost") private var remoteHost = "msi"
    @AppStorage("agentRemoteUsername") private var remoteUsername = ""
    @AppStorage("agentStepIndex") private var stepIndex = 0
    @AppStorage("agentComplete") private var agentComplete = false
    @State private var runLog: [String] = []

    private var proposedActionIsRisky: Bool {
        let command = proposedCommand.lowercased()
        let risk = proposalRisk.lowercased()
        if risk.contains("change") || risk.contains("write") || risk.contains("high") || risk.contains("destructive") || risk.contains("modify") {
            return true
        }
        let markers = [
            "remove-item", "clear-content", "format-volume", "format-disk",
            "restart-computer", "stop-computer", "shutdown", "set-executionpolicy",
            "disable-", "reg delete", "reg add", "invoke-expression", "iex ", "remove-",
            "set-content", "add-content", "new-item", "copy-item", "move-item",
            "rename-item", "set-service", "restart-service", "start-service",
            "stop-service", "set-itemproperty", "start-process", "install-", "uninstall-"
        ]
        return markers.contains { command.contains($0) }
    }

    var body: some View {
        Form {
            Section("Goal") {
                TextField("What should GhostGPT accomplish?", text: $goal, axis: .vertical)
                    .lineLimit(3...6)
                Button {
                    Task { await createPlan() }
                } label: {
                    Label(busy ? "Planning…" : "Plan task", systemImage: "sparkles")
                }.disabled(busy || preparingStep || executingStep || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    Task { await prepareNextStep() }
                } label: {
                    Label(preparingStep ? "Preparing next action…" : "Prepare next PowerShell action", systemImage: "arrow.trianglehead.2.clockwise")
                }.disabled(busy || preparingStep || executingStep || agentComplete || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("GhostGPT can propose one command at a time through your configured PowerShell gateway. It never runs a proposal automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Remote target") {
                TextField("Windows host or session name", text: $remoteHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username (if required by gateway)", text: $remoteUsername)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Every command requires an explicit approval. Potentially risky commands require a second confirmation. Gateway output is saved in the local run log; avoid commands that print secrets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Agent status") {
                Text(status)
                if agentComplete {
                    Label("The AI judged the goal may be complete. Review the run log before relying on that conclusion.", systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !plan.isEmpty {
                Section("Proposed plan") {
                    Text(plan).textSelection(.enabled)
                    Button("Copy plan") { UIPasteboard.general.string = plan }
                }
            }
            if !proposedCommand.isEmpty {
                Section("Review proposed action") {
                    Text(proposalPurpose.isEmpty ? "Proposed PowerShell command" : proposalPurpose)
                        .font(.headline)
                    if proposedActionIsRisky {
                        Text("Risk: \(proposalRisk)").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    } else {
                        Text("Risk: \(proposalRisk)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if !expectedResult.isEmpty {
                        Text("Expected result: \(expectedResult)").font(.footnote).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $proposedCommand)
                        .font(.system(.footnote, design: .monospaced)).frame(minHeight: 90)
                    Button {
                        if proposedActionIsRisky {
                            showingRiskConfirmation = true
                        } else {
                            Task { await executeApprovedStep() }
                        }
                    } label: {
                        Label(executingStep ? "Executing…" : "Approve and run step", systemImage: "checkmark.shield")
                    }.disabled(executingStep || preparingStep || proposedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Discard proposal", role: .destructive) {
                        proposedCommand = ""
                        status = "Proposal discarded. No command was run."
                    }.disabled(executingStep)
                }
            }
            if !runLog.isEmpty {
                Section("Resumable run log (\(runLog.count) entries)") {
                    ForEach(Array(runLog.enumerated()), id: \.offset) { item in
                        Text(item.element).font(.footnote).textSelection(.enabled)
                    }
                    Button("Clear log", role: .destructive) { runLog.removeAll() }
                }
            }
            Section("Available execution tool") {
                Label("Configured PowerShell HTTPS gateway", systemImage: "terminal")
                Text("This agent stage executes only through the configured gateway. MCP, browser, and SSH tools are not invoked by this loop yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("Configure PowerShell gateway") { TerminalGatewaySettingsView() }
            }
        }
        .navigationTitle("AI Agent")
        .onAppear {
            if goal.isEmpty { goal = savedGoal }
            if plan.isEmpty { plan = savedPlan }
            if status == "Ready" { status = savedStatus }
            if runLog.isEmpty {
                runLog = (try? JSONDecoder().decode([String].self, from: Data(savedLogJSON.utf8))) ?? []
            }
        }
        .onChange(of: goal) { value in savedGoal = value }
        .onChange(of: plan) { value in savedPlan = value }
        .onChange(of: status) { value in savedStatus = value }
        .onChange(of: runLog) { value in
            savedLogJSON = String(data: (try? JSONEncoder().encode(Array(value.prefix(100)))) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        }
        .confirmationDialog("Run a potentially risky PowerShell command?", isPresented: $showingRiskConfirmation, titleVisibility: .visible) {
            Button("Run risky command", role: .destructive) { Task { await executeApprovedStep(riskConfirmed: true) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The proposed command may change the remote computer. Review the command carefully before confirming.")
        }
    }

    @MainActor
    private func createPlan() async {
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else { return }
        busy = true
        status = "Requesting a plan from the AI service…"
        proposedCommand = ""
        agentComplete = false
        stepIndex = 0
        defer { busy = false }
        do {
            let instruction = """
            You are the planning component of GhostGPT. Create a safe, actionable plan for this goal:
            \(cleanGoal)
            Return 3-8 numbered steps. For each step state the intended action, evidence needed, success criteria, and a recovery path. Do not claim that you executed any tools. Do not request a function call or return tool-call JSON; respond with an ordinary readable plan. Prefer read-only inspection first.
            """
            let responseText = try await LocalModelClient.chat(
                endpoint: localModelEndpoint,
                model: localModelID,
                messages: [["role": "user", "content": instruction]],
                maxTokens: 512,
                timeout: 90
            )
            plan = responseText
            status = "Plan received. No tools have been executed."
            runLog.insert("Created plan for goal: \(cleanGoal)", at: 0)
            runLog = Array(runLog.prefix(100))
        } catch {
            status = "Planning failed: \(error.localizedDescription)"
            runLog.insert(status, at: 0)
            runLog = Array(runLog.prefix(100))
        }
    }

    @MainActor
    private func prepareNextStep() async {
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty, !agentComplete else { return }
        preparingStep = true
        status = "Planning the next action from the latest run results…"
        defer { preparingStep = false }
        do {
            let recentLog = runLog.prefix(12).reversed().joined(separator: "\n\n")
            let instruction = """
            You are GhostGPT's bounded PowerShell agent. Goal: \(cleanGoal)
            Current plan:
            \(plan)
            Recent execution results, newest last:
            \(recentLog.isEmpty ? "(No commands have been run yet.)" : recentLog)
            Remote host alias: \(remoteHost)
            Propose exactly ONE next PowerShell command that safely advances the goal. Use observed output to inspect success or recover from failures. Prefer read-only diagnostics. Never use encoded/obfuscated commands, credential dumping, exfiltration, deletion, formatting, security disabling, or policy bypass. If a necessary action would modify the system, mark risk as "changes" and explain it. If the goal appears complete based on evidence, set complete to true and command to an empty string.
            Return JSON only with keys: {"purpose":"short explanation","command":"one PowerShell command or empty string","risk":"read-only or changes","expectedResult":"observable outcome","complete":false}. Do not return a function call or Markdown fences.
            """
            let raw = try await LocalModelClient.chat(
                endpoint: localModelEndpoint,
                model: localModelID,
                messages: [["role": "user", "content": instruction]],
                maxTokens: 512,
                timeout: 90
            )
            guard let firstBrace = raw.firstIndex(of: "{"), let lastBrace = raw.lastIndex(of: "}"), firstBrace <= lastBrace,
                  let proposalData = String(raw[firstBrace...lastBrace]).data(using: .utf8),
                  let proposal = try JSONSerialization.jsonObject(with: proposalData) as? [String: Any] else {
                throw NSError(domain: "GhostGPTAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: "The AI did not return the required JSON action proposal. No command was run."])
            }
            if (proposal["complete"] as? Bool) == true {
                proposedCommand = ""
                agentComplete = true
                status = "The AI judged the goal may be complete based on the logged evidence. Review the run log."
                runLog.insert("Agent proposed completion after reviewing the latest results.", at: 0)
                runLog = Array(runLog.prefix(100))
                return
            }
            guard let command = proposal["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "GhostGPTAgent", code: 5, userInfo: [NSLocalizedDescriptionKey: "The AI proposal did not contain a runnable command. No command was run."])
            }
            proposedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            proposalPurpose = (proposal["purpose"] as? String) ?? "Next PowerShell action"
            proposalRisk = (proposal["risk"] as? String) ?? "review carefully"
            expectedResult = (proposal["expectedResult"] as? String) ?? ""
            status = "Action proposed. Review it and explicitly approve it before execution."
            runLog.insert("Proposed step \(stepIndex + 1): \(proposalPurpose) [risk: \(proposalRisk)]", at: 0)
            runLog = Array(runLog.prefix(100))
        } catch {
            status = "Next-step planning failed: \(error.localizedDescription)"
            runLog.insert(status, at: 0)
            runLog = Array(runLog.prefix(100))
        }
    }

    @MainActor
    private func executeApprovedStep(riskConfirmed: Bool = false) async {
        let submitted = proposedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty, !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let url = URL(string: gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil else {
            status = "Configure a valid HTTPS PowerShell gateway in Settings. No command was run."
            return
        }
        let token = KeychainStore.migratedValue(for: "terminalGatewayToken")
        guard !token.isEmpty else {
            status = "PowerShell gateway bearer token is missing. Configure it in Settings → Terminal gateway. No command was run."
            runLog.insert(status, at: 0)
            runLog = Array(runLog.prefix(100))
            return
        }
        executingStep = true
        defer { executingStep = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 65
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "mode": "powershell",
                "host": remoteHost,
                "username": remoteUsername,
                "command": submitted,
                "approved": true,
                "riskConfirmed": riskConfirmed
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let body = String(data: data, encoding: .utf8) ?? "(Non-text response)"
            let resultObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let httpSuccess = (200...299).contains(http.statusCode)
            let commandOK = resultObject?["ok"] as? Bool == true
            let exitCode = resultObject?["exit_code"] as? Int
            let exitCodeText = exitCode.map { String($0) } ?? "unknown"
            let success = httpSuccess && commandOK && (exitCode == nil || exitCode == 0)
            runLog.insert("Step \(stepIndex + 1) \(success ? "returned success" : "failed")\nPurpose: \(proposalPurpose)\nCommand: \(submitted)\nHTTP \(http.statusCode)\nCommand result: \(commandOK ? "ok" : "failed")\nExit code: \(exitCodeText)\nOutput: \(String(body.prefix(3000)))", at: 0)
            runLog = Array(runLog.prefix(100))
            if success { stepIndex += 1 }
            proposedCommand = ""
            status = success ? "Step succeeded. Inspecting output and preparing the next proposal…" : "Step failed (HTTP \(http.statusCode), command result \(commandOK ? "ok" : "failed"), exit code \(exitCodeText)). Inspecting the error and preparing a recovery proposal…"
            await prepareNextStep()
        } catch {
            runLog.insert("Step \(stepIndex + 1) could not reach the gateway: \(error.localizedDescription)", at: 0)
            runLog = Array(runLog.prefix(100))
            proposedCommand = ""
            status = "Gateway request failed. Preparing a recovery proposal; no result was received."
            await prepareNextStep()
        }
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("debugLogging") private var debugLogging = false
    var body: some View {
        Form {
            Section("AI routing") {
                Text("Chat, agent planning, and command drafting use the selected Cloudflare, Ollama, or LM Studio provider. Provider/model choices are kept separate; requests do not silently fall back to a different provider.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Performance") {
                Text("Fast mode uses a shorter model-response timeout; Balanced and Deep allow longer responses. Actual latency depends on the model and PC load.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Toggle("Debug logging", isOn: $debugLogging)
            }
            Section("Security") {
                Text("Keep gateway tokens in Keychain and on the protected PC. Do not expose raw shell services to the public internet.")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("Advanced Settings")
    }
}
