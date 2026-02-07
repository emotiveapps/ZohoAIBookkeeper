import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.framework(
    name: "BookkeeperCore",
    platforms: [.iOS, .macOS, .watchOS],
    dependencies: [
        .external(name: "ZohoBooksClient"),
        .external(name: "SwiftAnthropic")
    ],
    resources: ["config.json"]
)
