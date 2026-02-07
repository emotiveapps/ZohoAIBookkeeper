import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.app(
    name: "ZohoBookkeeperApp",
    dependencies: [
        .project(target: "BookkeeperCore", path: "../BookkeeperCore"),
        .external(name: "ZohoBooksClient"),
        .external(name: "SwiftAnthropic")
    ],
    resources: ["Resources/**"]
)
