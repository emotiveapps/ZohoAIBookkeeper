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

        Section {
            TextField("Entra Tenant ID", text: $form.receiptTenantId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Entra Client ID", text: $form.receiptClientId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Mailbox address", text: $form.receiptMailbox)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            TextField("OneDrive inbox folder", text: $form.oneDriveFolderPath)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Archive folder", text: $form.archiveFolderPath)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Receipts (optional)")
        } footer: {
            Text(
                "Microsoft 365 receipt capture: the Entra app + mailbox to sweep, "
                    + "the OneDrive folder used as a receipts inbox, and the OneDrive "
                    + "folder holding the receipt archive. Leave blank to disable."
            )
        }
    }
}

#Preview {
    SetupView()
        .environment(AppModel(credentialsStore: InMemoryCredentialsStore()))
}
