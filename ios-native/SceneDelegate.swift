import UIKit
import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

struct AIReply: Decodable { let reply: String }

struct AIError: Decodable { let error: String }

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
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
                .tabItem { Label("Chat", systemImage: "sparkles") }
                .tag(0)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(1)
        }
        .tint(Color(red: 0.25, green: 0.48, blue: 1.0))
        .preferredColorScheme(.dark)
    }
}

struct ChatView: View {
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @State private var draft = ""
    @State private var messages: [ChatMessage] = []
    @State private var isConnecting = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                Spacer()
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.blue)
                Text("GhostGPT").font(.largeTitle.bold()).padding(.top, 12)
                Text("Your private AI workspace").foregroundStyle(.secondary).padding(.top, 4)
                Text("Ask a question to get started.").foregroundStyle(.secondary).padding(.top, 18)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            Text(message.text).padding(12)
                                .background(message.isUser ? Color.blue : Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                        }
                        if isConnecting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("GhostGPT is thinking…").foregroundStyle(.secondary)
                            }.padding(12)
                        }
                    }.padding()
                }
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            HStack(spacing: 10) {
                TextField("Message GhostGPT…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).padding(12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
            }.padding()
        }
        .navigationTitle("GhostGPT")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(text: text, isUser: true))
        draft = ""
        errorText = nil
        isConnecting = true

        Task {
            defer { isConnecting = false }
            do {
                guard let baseURL = URL(string: serviceURL) else {
                    throw URLError(.badURL)
                }
                let url = baseURL.appendingPathComponent("chat")
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 45
                request.httpBody = try JSONEncoder().encode(["message": text])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (200..<300).contains(http.statusCode), let answer = try? JSONDecoder().decode(AIReply.self, from: data) {
                    messages.append(ChatMessage(text: answer.reply, isUser: false))
                } else {
                    let serviceError = try? JSONDecoder().decode(AIError.self, from: data)
                    throw NSError(domain: "GhostGPT", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: serviceError?.error ?? "The AI service could not answer right now."])
                }
            } catch {
                errorText = "Couldn’t reach GhostGPT. Check your connection or service address."
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    var body: some View {
        List {
            Section("Connection") {
                Label("Native SwiftUI interface", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("Cloudflare AI service", systemImage: "cloud.fill").foregroundStyle(.blue)
                Label("Cloudflare AI connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Section("Preferences") { Toggle("Notifications", isOn: $notificationsEnabled) }
            Section("Advanced") {
                NavigationLink("Advanced Settings") { AdvancedSettingsView() }
            }
            Section("Policies") {
                Text("Privacy Policy")
                Text("Terms of Use")
                Text("Acceptable Use & Safety")
            }
            Section { Text("GhostGPT native iOS • 1.0").foregroundStyle(.secondary) }
        }.navigationTitle("Settings")
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"
    @AppStorage("cloudflareEnabled") private var cloudflareEnabled = true
    @AppStorage("debugLogging") private var debugLogging = false
    var body: some View {
        Form {
            Section("Service") {
                TextField("Service URL", text: $serviceURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                Toggle("Use Cloudflare edge connection", isOn: $cloudflareEnabled)
            }
            Section("Diagnostics") {
                Toggle("Debug logging", isOn: $debugLogging)
                Button("Reset connection settings", role: .destructive) {
                    serviceURL = "https://ghostgpt-ai.conman31115.workers.dev"; cloudflareEnabled = true; debugLogging = false
                }
            }
            Section("Safety") {
                Text("Never store API keys, passwords, or private tokens in this app. Keep secrets on a protected server or Cloudflare Worker.")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("Advanced Settings")
    }
}
