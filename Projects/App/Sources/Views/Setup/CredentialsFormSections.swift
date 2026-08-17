import SwiftUI
import BookkeeperCore

struct CredentialsFormSections: View {
    @Binding var form: CredentialsFormModel

    var body: some View {
        Section("Zoho Books") {
            TextField("Client ID", text: $form.clientId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Client Secret", text: $form.clientSecret)
            SecureField("Access Token", text: $form.accessToken)
            SecureField("Refresh Token", text: $form.refreshToken)
            TextField("Organization ID", text: $form.organizationId)
                .autocorrectionDisabled()
                .keyboardType(.numberPad)
            Picker("Region", selection: $form.region) {
                Text("US (.com)").tag("com")
                Text("EU (.eu)").tag("eu")
                Text("India (.in)").tag("in")
                Text("Australia (.au)").tag("au")
            }
        }

        Section {
            SecureField("API Key", text: $form.anthropicApiKey)
        } header: {
            Text("Anthropic")
        } footer: {
            Text("Used for AI categorization suggestions.")
        }
    }
}

#Preview {
    SetupView()
        .environment(AppModel(credentialsStore: InMemoryCredentialsStore()))
}
