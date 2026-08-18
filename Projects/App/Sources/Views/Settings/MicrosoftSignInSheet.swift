import SwiftUI
import DesignSystem
import BookkeeperCore

/// Microsoft device-code sign-in: shows the code, opens the verification page,
/// and waits for the browser-side sign-in to complete. Tokens land in this
/// device's Keychain, unlocking mailbox + OneDrive sweeps from the app.
struct MicrosoftSignInSheet: View {
    let graph: MicrosoftGraphMailClient
    @Environment(\.dismiss) private var dismiss

    @State private var code: MicrosoftGraphMailClient.DeviceCode?
    @State private var errorMessage: String?
    @State private var finished = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.Colors.success)
                    Text("Signed in")
                        .font(.title2.weight(.semibold))
                } else if let errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.Colors.warning)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        self.errorMessage = nil
                        code = nil
                        Task { await run() }
                    }
                    .buttonStyle(.borderedProminent)
                } else if let code {
                    Text("Enter this code on the Microsoft sign-in page, using the account with access to the billing mailbox:")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text(code.userCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)

                    #if os(iOS)
                    Button {
                        UIPasteboard.general.string = code.userCode
                    } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                    }
                    #endif

                    if let url = URL(string: code.verificationURI) {
                        Link(destination: url) {
                            Label("Open Sign-In Page", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    ProgressView("Waiting for you to finish signing in…")
                        .padding(.top, 8)
                } else {
                    ProgressView("Requesting sign-in code…")
                }
            }
            .padding()
            .navigationTitle("Microsoft Sign-In")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await run() }
            // Completing sign-in means a round-trip through the browser; the
            // app suspends mid-poll and the resumed poll can fail or be
            // superseded. On every return to foreground, trust the Keychain.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !finished {
                    Task { await checkAlreadySignedIn() }
                }
            }
        }
    }

    private func checkAlreadySignedIn() async {
        if await graph.isSignedIn {
            await finishAndDismiss()
        }
    }

    private func finishAndDismiss() async {
        errorMessage = nil
        finished = true
        try? await Task.sleep(for: .seconds(1))
        dismiss()
    }

    private func run() async {
        do {
            let deviceCode = try await graph.beginDeviceLogin()
            code = deviceCode
            try await graph.waitForLogin(deviceCode)
            await finishAndDismiss()
        } catch {
            // A poll interrupted by backgrounding can throw after the tokens
            // were already stored — check the Keychain before surfacing.
            if await graph.isSignedIn {
                await finishAndDismiss()
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
