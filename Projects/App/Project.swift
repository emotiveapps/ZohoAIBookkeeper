import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
    name: "ZohoBookkeeperApp",
    dependencies: [
        .project(target: "BookkeeperCore", path: "../BookkeeperCore"),
        .external(name: "ZohoBooksClient"),
        .external(name: "DesignSystem"),
        .external(name: "SwiftAnthropic")
    ],
    resources: ["Resources/**"],
    entitlements: "Entitlements/ZohoBookkeeperApp.entitlements",
    shareExtension: Project.ShareExtensionSpec(
        name: "ShareExtension",
        sources: ["ShareExtension/Sources/**"],
        entitlements: "Entitlements/ShareExtension.entitlements"
    ),
    // Defined here (not in Projects/Watch) so Tuist embeds it in the iOS app —
    // see WatchAppSpec. The sources still live under Projects/Watch.
    watchApp: Project.WatchAppSpec(
        name: "ZohoBookkeeperWatch",
        sources: ["../Watch/Sources/**"],
        resources: ["../Watch/Resources/**"],
        entitlements: "../Watch/Entitlements/ZohoBookkeeperWatch.entitlements",
        dependencies: [
            .project(target: "BookkeeperCore", path: "../BookkeeperCore"),
            .external(name: "ZohoBooksClient")
        ],
        widget: Project.WatchWidgetSpec(
            name: "ZohoBookkeeperWatchWidgets",
            // PendingCountStorage is shared with the watch app (the app
            // writes what the widget's timeline provider reads).
            sources: [
                "../Watch/Widgets/Sources/**",
                "../Watch/Sources/PendingCountStorage.swift"
            ],
            entitlements: "../Watch/Entitlements/ZohoBookkeeperWatchWidgets.entitlements"
        )
    )
)
