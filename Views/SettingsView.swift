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
    
    @State private var tokenToDelete: TokenInfo? = nil
    @State private var showingDeleteConfirmation = false

    private func confirmDelete(_ token: TokenInfo) {
        tokenToDelete = token
        showingDeleteConfirmation = true
    }
    
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
                    if settings.isEnrichingTokens {
                        HStack {
                            ProgressView()
                            Text("Fetching user info…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settings.tokens.isEmpty {
                        Text("No tokens added yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(settings.tokens) { tokenInfo in
                            let isLocal = tokenInfo.id == TokenInfo.localDeviceToken.id

                            HStack {
                                Text(tokenInfo.identifier)
                                    .font(.headline)
                                    .foregroundStyle(isLocal ? .secondary : .primary)

                                Spacer()

                                if let email = tokenInfo.email {
                                    HStack(spacing: 4) {
                                        Image(systemName: "envelope")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(email)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .if(!isLocal) { view in
                                view.onTapGesture {
                                    editingToken = tokenInfo
                                    newTokenIdentifier = tokenInfo.identifier
                                    newTokenString = tokenInfo.token
                                    showAddTokenSheet = true
                                }
                            }
                            .swipeActions {
                                if !isLocal {
                                    Button(role: .none) {
                                        confirmDelete(tokenInfo)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                                    
                            }
                            .contextMenu {
                                if !isLocal {
                                    Button(role: .none) {
                                        confirmDelete(tokenInfo)
                                    } label: {
                                        Label("Delete...", systemImage: "trash")
                                    }
                                } else {
                                    Text("This Device token cannot be deleted")
                                        .foregroundColor(.gray)
                                }
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
                if let editingToken = editingToken {
                    TokenEditSheet(
                        tokenInfo: settings.tokens.first(where: { $0.id == editingToken.id }),
                        tokenIdentifier: $newTokenIdentifier,
                        tokenString: $newTokenString,
                        onSave: {
                            if let index = settings.tokens.firstIndex(where: { $0.id == editingToken.id }) {
                                settings.tokens[index].token = newTokenString
                                settings.tokens[index].identifier = newTokenIdentifier
                                
                                let updatedToken = settings.tokens[index]
                                Task {
                                    await ShoppingListAPI.shared.enrichTokensWithUserInfo(tokens: [updatedToken])
                                }
                            }
                            showAddTokenSheet = false
                        },
                        onCancel: {
                            showAddTokenSheet = false
                        }
                    )
                } else {
                    TokenEditSheet(
                        tokenInfo: nil,
                        tokenIdentifier: $newTokenIdentifier,
                        tokenString: $newTokenString,
                        onSave: {
                            let newToken = TokenInfo(token: newTokenString, identifier: newTokenIdentifier)
                            settings.addToken(newToken)
                            
                            Task {
                                await ShoppingListAPI.shared.enrichTokensWithUserInfo(tokens: [newToken])
                            }
                            
                            showAddTokenSheet = false
                        },
                        onCancel: {
                            showAddTokenSheet = false
                        }
                    )
                }
            }
            .id(editingToken?.id)
        
        }
        .alert("Delete Token?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let token = tokenToDelete {
                    settings.removeToken(token)
                }
                tokenToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                tokenToDelete = nil
            }
        } message: {
            if let token = tokenToDelete {
                Text("Are you sure you want to delete the token for “\(token.identifier)”?")
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
