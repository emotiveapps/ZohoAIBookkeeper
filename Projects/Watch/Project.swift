import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.watchApp(
    name: "ZohoBookkeeperWatch",
    dependencies: [
        .project(target: "BookkeeperCore", path: "../BookkeeperCore"),
        .external(name: "ZohoBooksClient")
    ]
)
