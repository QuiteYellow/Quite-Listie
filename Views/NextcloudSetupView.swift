//
//  NextcloudSetupView.swift
//  Listie.md
//
//  Connects to Nextcloud using Login Flow v2 (opens the server's web sign-in page
//  in the external browser) or falls back to manual app-password entry.
//

import SwiftUI

struct NextcloudSetupView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with saved credentials after a successful connection.
    var onConnected: (NextcloudCredentials) -> Void

    // MARK: - Login Flow v2 state
    @State private var serverURL = ""
    @State private var isStartingFlow = false   // spinner while fetching the login URL
    @State private var isFlowPending = false    // polling — waiting for user to finish in browser
    @State private var pollTask: Task<Void, Never>? = nil

    // MARK: - Manual sign-in state
    @State private var showManual = false
    @State private var username = ""
    @State private var appPassword = ""
    @State private var isTesting = false
    @State private var testResult: TestResult? = nil
    @State private var isSaving = false

    @State private var errorMessage: String? = nil

    enum TestResult {
        case success(String)
        case failure(String)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                loginFlowSection
                if let msg = errorMessage { errorSection(msg) }
                manualSection
            }
            .navigationTitle("Connect to Nextcloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelLoginFlow()
                        dismiss()
                    }
                }
                if showManual && isManualFormValid {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect") { saveAndConnectManual() }
                            .disabled(isSaving)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            TextField("https://cloud.example.com", text: $serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: serverURL) { _, _ in
                    errorMessage = nil
                    testResult = nil
                }
        } header: {
            Text("Server")
        } footer: {
            Text("The address of your Nextcloud server.")
        }
    }

    private var loginFlowSection: some View {
        Section {
            if isFlowPending {
                HStack(spacing: 14) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Waiting for sign-in…")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Complete the login in Safari, then return here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Button("Cancel Sign-in", role: .destructive) {
                    cancelLoginFlow()
                }
            } else {
                Button {
                    Task { await startLoginFlow() }
                } label: {
                    HStack(spacing: 10) {
                        if isStartingFlow {
                            ProgressView()
                        } else {
                            Image(systemName: "person.badge.key.fill")
                                .foregroundStyle(.blue)
                        }
                        Text("Sign in with Nextcloud")
                            .fontWeight(.medium)
                    }
                }
                .disabled(serverURLCleaned.isEmpty || isStartingFlow)
            }
        } footer: {
            if !isFlowPending {
                Text("Opens your Nextcloud sign-in page in Safari. Supports 2FA and SSO — no app passwords needed.")
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var manualSection: some View {
        Section {
            DisclosureGroup("Sign in manually", isExpanded: $showManual) {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("App Password", text: $appPassword)

                Button {
                    testConnection()
                } label: {
                    HStack {
                        Text("Test Connection")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(!isManualFormValid || isTesting)

                if let result = testResult {
                    switch result {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        } footer: {
            if showManual {
                Link("How to create an app password →",
                     destination: URL(string: "https://docs.nextcloud.com/server/latest/user_manual/en/session_management.html")!)
                    .font(.footnote)
            }
        }
    }

    // MARK: - Login Flow v2

    private func startLoginFlow() async {
        errorMessage = nil
        isStartingFlow = true
        do {
            let (loginURL, token, endpoint) = try await NextcloudManager.shared.startLoginFlowV2(
                serverURL: serverURLCleaned
            )
            isStartingFlow = false
            isFlowPending = true

            // Open the Nextcloud login page in Safari.
            // Using external browser avoids sheet-inside-sheet presentation issues.
            await UIApplication.shared.open(loginURL)

            // Poll every 2 s in the background while the user signs in.
            pollTask = Task { await pollForCredentials(token: token, endpoint: endpoint) }
        } catch {
            isStartingFlow = false
            errorMessage = error.localizedDescription
        }
    }

    private func pollForCredentials(token: String, endpoint: String) async {
        let deadline = Date().addingTimeInterval(20 * 60)   // token valid for 20 min
        while !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            if let creds = await NextcloudManager.shared.pollLoginFlowV2(token: token, endpoint: endpoint) {
                await MainActor.run { finishFlow(with: creds) }
                return
            }
        }
        await MainActor.run {
            isFlowPending = false
            errorMessage = "Sign-in timed out. Please try again."
        }
    }

    @MainActor
    private func finishFlow(with creds: NextcloudCredentials) {
        isFlowPending = false
        do {
            try creds.save()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        Task {
            await NextcloudManager.shared.setup(credentials: creds)
            onConnected(creds)
            dismiss()
        }
    }

    private func cancelLoginFlow() {
        pollTask?.cancel()
        pollTask = nil
        isFlowPending = false
        isStartingFlow = false
    }

    // MARK: - Manual sign-in

    private var serverURLCleaned: String {
        var url = serverURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        if !url.isEmpty && !url.hasPrefix("http") { url = "https://\(url)" }
        return url
    }

    private var isManualFormValid: Bool {
        !serverURLCleaned.isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !appPassword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func testConnection() {
        let creds = makeManualCreds()
        isTesting = true
        testResult = nil
        Task {
            do {
                await NextcloudManager.shared.setup(credentials: creds)
                let files = try await NextcloudManager.shared.listFiles(at: "/")
                testResult = .success("Connected — \(files.count) item(s) at root")
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func saveAndConnectManual() {
        let creds = makeManualCreds()
        isSaving = true
        Task {
            do {
                try creds.save()
                await NextcloudManager.shared.setup(credentials: creds)
                onConnected(creds)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func makeManualCreds() -> NextcloudCredentials {
        NextcloudCredentials(
            serverURL: serverURLCleaned,
            username: username.trimmingCharacters(in: .whitespaces),
            appPassword: appPassword
        )
    }
}

#Preview {
    NextcloudSetupView { _ in }
}
