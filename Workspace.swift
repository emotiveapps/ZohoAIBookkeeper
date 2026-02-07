import ProjectDescription

let workspace = Workspace(
    name: "ZohoAIBookkeeper",
    projects: [
        "Projects/BookkeeperCore",
        "Projects/CLI",
        "Projects/App",
        "Projects/Watch"
    ],
    schemes: [
        .scheme(
            name: "ZohoAIBookkeeper-All",
            buildAction: .buildAction(targets: [
                .project(path: "Projects/BookkeeperCore", target: "BookkeeperCore"),
                .project(path: "Projects/CLI", target: "ZohoBookkeeperCLI"),
                .project(path: "Projects/App", target: "ZohoBookkeeperApp"),
                .project(path: "Projects/Watch", target: "ZohoBookkeeperWatch")
            ])
        )
    ]
)
