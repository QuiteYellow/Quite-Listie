import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server URL")) {
                                    TextField("Server URL", text: $settings.serverURLString)
                                        .disableAutocorrection(true)
                                        .autocapitalization(.none)
                                        .keyboardType(.URL)
                                }
                
                Section(header: Text("API Token")) {
                    SecureField("Bearer Token", text: $settings.apiToken)
                        .disableAutocorrection(true)
                }

                Section(header: Text("Cloudflare Access")) {
                    Toggle("Enable Cloudflare Access", isOn: $settings.cloudflareAccessEnabled)
                    
                    if settings.cloudflareAccessEnabled {
                        SecureField("CF-Access-Client-Id", text: $settings.cfAccessClientId)
                            .disableAutocorrection(true)
                            .textContentType(.username)
                        
                        SecureField("CF-Access-Client-Secret", text: $settings.cfAccessClientSecret)
                            .disableAutocorrection(true)
                            .textContentType(.password)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
