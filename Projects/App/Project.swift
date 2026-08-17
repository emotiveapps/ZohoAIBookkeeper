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
    )
)
