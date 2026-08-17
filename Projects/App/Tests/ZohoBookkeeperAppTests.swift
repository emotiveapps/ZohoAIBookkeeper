import Testing
@testable import ZohoBookkeeperApp
import BookkeeperCore

@Suite("AppModel")
struct AppModelTests {

    @Test("Starts in loading phase")
    @MainActor
    func startsLoading() {
        let model = AppModel(credentialsStore: InMemoryCredentialsStore())
        guard case .loading = model.phase else {
            Issue.record("Expected .loading, got \(model.phase)")
            return
        }
        #expect(model.workspace == nil)
    }

    @Test("Bootstrap without stored credentials lands on setup")
    @MainActor
    func bootstrapWithoutCredentials() async {
        let model = AppModel(credentialsStore: InMemoryCredentialsStore())
        await model.bootstrap()
        guard case .needsSetup = model.phase else {
            Issue.record("Expected .needsSetup, got \(model.phase)")
            return
        }
    }

    @Test("Sign out clears stored credentials")
    @MainActor
    func signOutClears() async throws {
        let store = InMemoryCredentialsStore(
            initial: FullConfiguration(
                zoho: ZohoConfiguration(
                    clientId: "id", clientSecret: "secret",
                    accessToken: "at", refreshToken: "rt",
                    organizationId: "org", region: "com"
                ),
                anthropic: AnthropicConfiguration(apiKey: "key")
            )
        )
        let model = AppModel(credentialsStore: store)
        model.signOut()
        #expect(try store.load() == nil)
        guard case .needsSetup = model.phase else {
            Issue.record("Expected .needsSetup, got \(model.phase)")
            return
        }
    }
}

@Suite("CredentialsFormModel")
struct CredentialsFormModelTests {

    private var sampleConfig: FullConfiguration {
        FullConfiguration(
            zoho: ZohoConfiguration(
                clientId: "id", clientSecret: "secret",
                accessToken: "at", refreshToken: "rt",
                organizationId: "org", region: "eu"
            ),
            anthropic: AnthropicConfiguration(apiKey: "key"),
            categoryMapping: CategoryMappingConfig(categories: [
                CategoryConfig(name: "Parent", children: ["Child A", "Child B"])
            ])
        )
    }

    @Test("Round-trips a configuration including category mapping")
    func roundTrip() {
        var form = CredentialsFormModel()
        #expect(!form.isValid)

        form.apply(sampleConfig)
        #expect(form.isValid)
        #expect(form.region == "eu")

        let rebuilt = form.configuration
        #expect(rebuilt.zoho.clientId == "id")
        #expect(rebuilt.categoryMapping?.allCategoryNames == ["Parent", "Child A", "Child B"])
    }
}
