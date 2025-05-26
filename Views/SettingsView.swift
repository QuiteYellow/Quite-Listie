import SwiftUI

struct TokenView: View {
    let token: String
    @State private var isRevealed = false
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: { isRevealed.toggle() }) {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundColor(.blue)
            }
            .buttonStyle(BorderlessButtonStyle())
            Text(isRevealed ? token : String(repeating: "•", count: max(8, token.count)))
                //.font(.caption2)
                .foregroundColor(.gray)
                .lineLimit(1)
                .truncationMode(.tail)
            
            
        }
    }
}

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    
    // Local state for adding/editing tokens
    @State private var newTokenString = ""
    @State private var newTokenIdentifier = ""
    @State private var editingToken: TokenInfo? = nil
    @State private var showAddTokenSheet = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server URL")) {
                    TextField("Server URL", text: $settings.serverURLString)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }
                
                Section(header: Text("API Tokens")) {
                    if settings.tokens.isEmpty {
                        Text("No tokens added yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(settings.tokens) { tokenInfo in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(tokenInfo.identifier)
                                        .font(.headline)
                                    TokenView(token: tokenInfo.token)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    withAnimation {
                                        settings.removeToken(tokenInfo)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingToken = tokenInfo
                                newTokenIdentifier = tokenInfo.identifier
                                newTokenString = tokenInfo.token
                                showAddTokenSheet = true
                            }
                        }
                    }
                    
                    Button(action: {
                        editingToken = nil
                        newTokenIdentifier = ""
                        newTokenString = ""
                        showAddTokenSheet = true
                    }) {
                        Label("Add Token", systemImage: "plus")
                    }
                }
                
                Section(header: Text("Cloudflare Access")) {
                    Toggle("Enable Cloudflare Access", isOn: $settings.cloudflareAccessEnabled)

                    if settings.cloudflareAccessEnabled {
                        Text("CF-Access-Client-Id:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("CF-Access-Client-Id", text: $settings.cfAccessClientId)
                            .disableAutocorrection(true)
                            .textContentType(.username)
                        
                        Text("CF-Access-Client-Secret:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        SecureField("CF-Access-Client-Secret", text: $settings.cfAccessClientSecret)
                            .disableAutocorrection(true)
                            .textContentType(.password)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showAddTokenSheet) {
                TokenEditView(
                    tokenString: $newTokenString,
                    tokenIdentifier: $newTokenIdentifier,
                    onSave: {
                        if var editing = editingToken {
                            // Update existing token
                            if let index = settings.tokens.firstIndex(where: { $0.id == editing.id }) {
                                settings.tokens[index].token = newTokenString
                                settings.tokens[index].identifier = newTokenIdentifier
                            }
                        } else {
                            // Add new token
                            let newToken = TokenInfo(token: newTokenString, identifier: newTokenIdentifier)
                            settings.addToken(newToken)
                        }
                        showAddTokenSheet = false
                    },
                    onCancel: {
                        showAddTokenSheet = false
                    }
                )
            }
        }
    }
}

struct TokenEditView: View {
    @Binding var tokenString: String
    @Binding var tokenIdentifier: String
    
    var onSave: () -> Void
    var onCancel: () -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Token Identifier")) {
                    TextField("Identifier (e.g. Account name)", text: $tokenIdentifier)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                }
                
                Section(header: Text("Token")) {
                    SecureField("Bearer Token", text: $tokenString)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Edit Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !tokenString.isEmpty, !tokenIdentifier.isEmpty else { return }
                        onSave()
                    }
                    .disabled(tokenString.isEmpty || tokenIdentifier.isEmpty)
                }
            }
        }
    }
}
