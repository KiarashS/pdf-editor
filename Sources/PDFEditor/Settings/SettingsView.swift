import PDFEditorCore
import Security
import SwiftUI

enum SettingsKeys {
    static let model = "ai.model"
    static let effort = "ai.effort"
    static let authorName = "annotations.author"
}

/// Stores the Anthropic API key in the login keychain.
enum APIKeyStore {
    private static let service = "PDFEditor.AnthropicAPIKey"
    private static let account = "default"

    /// The saved key, or `ANTHROPIC_API_KEY` from the environment.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var attributes = base
        attributes[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettings()
                .tabItem { Label("AI Assistant", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 320)
    }
}

struct GeneralSettings: View {
    @AppStorage(SettingsKeys.authorName) private var authorName = NSFullUserName()

    var body: some View {
        Form {
            TextField("Author name for comments", text: $authorName)
                .onChange(of: authorName) { AnnotationFactory.authorName = authorName }
            Text("New highlights, notes and drawings are signed with this name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct AISettings: View {
    @AppStorage(SettingsKeys.model) private var model = ClaudeConfiguration.defaultModel
    @AppStorage(SettingsKeys.effort) private var effort = "medium"
    @State private var apiKey = ""
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("Anthropic API key", text: $apiKey)
            HStack {
                Button("Save Key") {
                    saved = APIKeyStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if saved { Text("Saved to Keychain").foregroundStyle(.secondary) }
            }
            Picker("Model", selection: $model) {
                ForEach(ClaudeConfiguration.availableModels, id: \.self) { Text($0).tag($0) }
            }
            Picker("Effort", selection: $effort) {
                ForEach(ClaudeConfiguration.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Text("The open PDF is sent to the Claude API when you use the assistant. Higher effort gives more thorough answers and uses more tokens. Get a key at console.anthropic.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { apiKey = APIKeyStore.load() ?? "" }
    }
}
