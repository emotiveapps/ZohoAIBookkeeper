import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.cliTool(
    name: "ZohoBookkeeperCLI",
    dependencies: [
        .project(target: "BookkeeperCore", path: "../BookkeeperCore"),
        .external(name: "ZohoBooksClient"),
        .external(name: "SwiftAnthropic"),
        .external(name: "ArgumentParser")
    ]
)
