import SwiftUI
import FountainKit
import GoatCore

/// Paste-a-key sign-in against any Fountain deployment. OAuth ("Sign in with
/// Fountain") can layer on later; the token it yields is an API key, so this
/// flow doesn't change shape.
struct ConnectView: View {
    @SwiftUI.Environment(Session.self) private var session
    @State private var baseURLText = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "drop.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Connect to Fountain")
                .font(.title2.bold())

            Form {
                TextField("Server", text: $baseURLText, prompt: Text(FountainConfig.defaultBaseURL.absoluteString))
                    .textContentType(.URL)
                SecureField("API key", text: $apiKey, prompt: Text("ftn_live_…"))
            }
            .formStyle(.columns)
            .frame(maxWidth: 380)

            if case .failed(let message) = session.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 380)
            }

            Button {
                Task { await connect() }
            } label: {
                if session.state == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.isEmpty || session.state == .checking)

            Text("Get a key from your Fountain console under API keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            baseURLText = session.baseURL.absoluteString
        }
    }

    private func connect() async {
        var trimmed = baseURLText.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.isEmpty, let url = URL(string: trimmed) {
            session.baseURL = url
        }
        await session.connect(apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }
}

struct SettingsView: View {
    @SwiftUI.Environment(Session.self) private var session

    var body: some View {
        Form {
            LabeledContent("Server", value: session.baseURL.absoluteString)
            if case .signedIn(let email) = session.state {
                LabeledContent("Signed in as", value: email)
                Button("Sign out") { session.signOut() }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
