import SwiftUI

struct TokenEditSheet: View {
    let tokenInfo: TokenInfo?
    @Binding var tokenIdentifier: String
    @Binding var tokenString: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
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

                    Section {
                        DisclosureGroup("Details") {
                            if let tokenInfo = tokenInfo {
                                if let fullName = tokenInfo.fullName {
                                    Label(fullName, systemImage: "person.fill")
                                }
                                if let username = tokenInfo.username {
                                    Label("Username: \(username)", systemImage: "person.circle")
                                }
                                if let email = tokenInfo.email {
                                    Label(email, systemImage: "envelope")
                                }
                                if let groupSlug = tokenInfo.groupSlug {
                                    Label("Group: \(groupSlug)", systemImage: "tag")
                                }
                                if let groupId = tokenInfo.groupId {
                                    Label("Group ID: \(groupId)", systemImage: "number")
                                }
                                if let household = tokenInfo.household {
                                    Label("Household: \(household)", systemImage: "house")
                                }
                                if let householdId = tokenInfo.householdId {
                                    Label("Household ID: \(householdId)", systemImage: "number")
                                }
                                if let isAdmin = tokenInfo.isAdmin {
                                    Label(isAdmin ? "Admin: Yes" : "Admin: No", systemImage: "lock.shield")
                                }
                                if let canManage = tokenInfo.canManage {
                                    Label("Can Manage: \(canManage ? "Yes" : "No")", systemImage: "gear")
                                }
                            } else {
                                Text("Loading details…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    
                }
            }
            .navigationTitle(tokenInfo == nil ? "Add Token" : "Edit Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(tokenIdentifier.isEmpty || tokenString.isEmpty)
                }
            }
        }
    }
}
