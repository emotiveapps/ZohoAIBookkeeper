import ProjectDescription

// MARK: - Constants

public enum Constants {
    public static let organizationName = "com.andrewash"
    public static let deploymentTargets = DeploymentTargets(
        iOS: "17.0",
        macOS: "14.0",
        watchOS: "10.0"
    )
}

// MARK: - Project Factory

public extension Project {

    /// Creates a framework project
    static func framework(
        name: String,
        platforms: Set<Platform> = [.iOS, .macOS, .watchOS],
        dependencies: [TargetDependency] = [],
        sources: SourceFilesList = ["Sources/**"],
        resources: ResourceFileElements? = nil
    ) -> Project {
        let targets: [Target] = [
            .target(
                name: name,
                destinations: destinations(for: platforms),
                product: .framework,
                bundleId: "\(Constants.organizationName).\(name)",
                deploymentTargets: Constants.deploymentTargets,
                sources: sources,
                resources: resources,
                dependencies: dependencies
            ),
            .target(
                name: "\(name)Tests",
                destinations: destinations(for: platforms),
                product: .unitTests,
                bundleId: "\(Constants.organizationName).\(name)Tests",
                deploymentTargets: Constants.deploymentTargets,
                sources: ["Tests/**"],
                dependencies: [.target(name: name)]
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            targets: targets
        )
    }

    /// Creates a macOS CLI tool project
    static func cliTool(
        name: String,
        dependencies: [TargetDependency] = [],
        sources: SourceFilesList = ["Sources/**"]
    ) -> Project {
        let targets: [Target] = [
            .target(
                name: name,
                destinations: [.mac],
                product: .commandLineTool,
                bundleId: "\(Constants.organizationName).\(name)",
                deploymentTargets: Constants.deploymentTargets,
                sources: sources,
                dependencies: dependencies,
                settings: .settings(
                    base: ["SWIFT_VERSION": "6.0"]
                )
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            targets: targets
        )
    }

    /// Creates an iOS app project
    static func app(
        name: String,
        dependencies: [TargetDependency] = [],
        sources: SourceFilesList = ["Sources/**"],
        resources: ResourceFileElements? = nil,
        entitlements: Entitlements? = nil
    ) -> Project {
        let targets: [Target] = [
            .target(
                name: name,
                destinations: [.iPhone, .iPad],
                product: .app,
                bundleId: "\(Constants.organizationName).\(name)",
                deploymentTargets: Constants.deploymentTargets,
                infoPlist: .extendingDefault(with: [
                    "UILaunchScreen": [
                        "UIColorName": "",
                        "UIImageName": "",
                    ],
                    "UISupportedInterfaceOrientations": [
                        "UIInterfaceOrientationPortrait",
                        "UIInterfaceOrientationLandscapeLeft",
                        "UIInterfaceOrientationLandscapeRight"
                    ]
                ]),
                sources: sources,
                resources: resources,
                entitlements: entitlements,
                dependencies: dependencies,
                settings: .settings(
                    base: ["SWIFT_VERSION": "6.0"]
                )
            ),
            .target(
                name: "\(name)Tests",
                destinations: [.iPhone, .iPad],
                product: .unitTests,
                bundleId: "\(Constants.organizationName).\(name)Tests",
                deploymentTargets: Constants.deploymentTargets,
                sources: ["Tests/**"],
                dependencies: [.target(name: name)]
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            targets: targets
        )
    }

    /// Creates a watchOS app project
    static func watchApp(
        name: String,
        dependencies: [TargetDependency] = [],
        sources: SourceFilesList = ["Sources/**"],
        resources: ResourceFileElements? = nil
    ) -> Project {
        let targets: [Target] = [
            .target(
                name: name,
                destinations: [.appleWatch],
                product: .app,
                bundleId: "\(Constants.organizationName).\(name)",
                deploymentTargets: Constants.deploymentTargets,
                infoPlist: .extendingDefault(with: [
                    "WKApplication": true,
                    "WKCompanionAppBundleIdentifier": "\(Constants.organizationName).ZohoBookkeeperApp"
                ]),
                sources: sources,
                resources: resources,
                dependencies: dependencies,
                settings: .settings(
                    base: ["SWIFT_VERSION": "6.0"]
                )
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            targets: targets
        )
    }

    // MARK: - Helpers

    private static func destinations(for platforms: Set<Platform>) -> Destinations {
        var destinations: Destinations = []
        if platforms.contains(.iOS) {
            destinations.insert(.iPhone)
            destinations.insert(.iPad)
        }
        if platforms.contains(.macOS) {
            destinations.insert(.mac)
        }
        if platforms.contains(.watchOS) {
            destinations.insert(.appleWatch)
        }
        return destinations
    }
}
