import UIKit
import SwiftUI

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: GhostGPTRootView())
        window.makeKeyAndVisible()
        self.window = window
        return true
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
    @State private var draft = ""
    @State private var messages: [(String, Bool)] = []
    @State private var isConnecting = false

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                Spacer()
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.blue)
                Text("GhostGPT").font(.largeTitle.bold()).padding(.top, 12)
                Text("Native iOS workspace").foregroundStyle(.secondary).padding(.top, 4)
                Text("Ask a question to get started.").foregroundStyle(.secondary).padding(.top, 18)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, item in
                            Text(item.0).padding(12)
                                .background(item.1 ? Color.blue : Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .frame(maxWidth: .infinity, alignment: item.1 ? .trailing : .leading)
                        }
                    }.padding()
                }
            }
            HStack(spacing: 10) {
                TextField("Message GhostGPT…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).padding(12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Button { send() } label: {
                    Image(systemName: isConnecting ? "hourglass" : "arrow.up.circle.fill").font(.system(size: 28))
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
            }.padding()
        }
        .navigationTitle("GhostGPT")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append((text, true)); draft = ""; isConnecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            messages.append(("Native UI is ready. Connect your GhostGPT service API to enable responses.", false))
            isConnecting = false
        }
    }
}

struct SettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    var body: some View {
        List {
            Section("Connection") {
                Label("Native SwiftUI interface", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("Cloudflare-ready deployment", systemImage: "cloud.fill").foregroundStyle(.blue)
                Label("Service API not configured", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
    @AppStorage("serviceURL") private var serviceURL = "https://ghostgpt.live"
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
                    serviceURL = "https://ghostgpt.live"; cloudflareEnabled = true; debugLogging = false
                }
            }
            Section("Safety") {
                Text("Never store API keys, passwords, or private tokens in this app. Keep secrets on a protected server or Cloudflare Worker.")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("Advanced Settings")
    }
}
