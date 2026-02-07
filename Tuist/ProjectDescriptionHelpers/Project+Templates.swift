import ProjectDescription

// MARK: - Constants

public enum Constants {
    public static let organizationName = "com.emotiveapps"
    public static let developmentTeam = "M7T8YXH895"
    public static let iOSVersion = "17.0"
    public static let macOSVersion = "14.0"
    public static let watchOSVersion = "10.0"

    public static let sharedSettings: SettingsDictionary = [
        "DEVELOPMENT_TEAM": .string(developmentTeam),
        "CODE_SIGN_STYLE": "Automatic",
        "SWIFT_VERSION": "6.0",
        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    ]

    public static func deploymentTargets(for platforms: Set<Platform>) -> DeploymentTargets {
        .multiplatform(
            iOS: platforms.contains(.iOS) ? iOSVersion : nil,
            macOS: platforms.contains(.macOS) ? macOSVersion : nil,
            watchOS: platforms.contains(.watchOS) ? watchOSVersion : nil
        )
    }
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
        let deploymentTargets = Constants.deploymentTargets(for: platforms)
        let targets: [Target] = [
            .target(
                name: name,
                destinations: destinations(for: platforms),
                product: .framework,
                bundleId: "\(Constants.organizationName).\(name)",
                deploymentTargets: deploymentTargets,
                sources: sources,
                resources: resources,
                dependencies: dependencies
            ),
            .target(
                name: "\(name)Tests",
                destinations: destinations(for: platforms),
                product: .unitTests,
                bundleId: "\(Constants.organizationName).\(name)Tests",
                deploymentTargets: deploymentTargets,
                sources: ["Tests/**"],
                dependencies: [.target(name: name)]
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            settings: .settings(base: Constants.sharedSettings),
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
                deploymentTargets: Constants.deploymentTargets(for: [.macOS]),
                sources: sources,
                dependencies: dependencies
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            settings: .settings(base: Constants.sharedSettings),
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
                deploymentTargets: Constants.deploymentTargets(for: [.iOS]),
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
                dependencies: dependencies
            ),
            .target(
                name: "\(name)Tests",
                destinations: [.iPhone, .iPad],
                product: .unitTests,
                bundleId: "\(Constants.organizationName).\(name)Tests",
                deploymentTargets: Constants.deploymentTargets(for: [.iOS]),
                sources: ["Tests/**"],
                dependencies: [.target(name: name)]
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            settings: .settings(base: Constants.sharedSettings),
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
                deploymentTargets: Constants.deploymentTargets(for: [.watchOS]),
                infoPlist: .extendingDefault(with: [
                    "WKApplication": true,
                    "WKCompanionAppBundleIdentifier": "\(Constants.organizationName).ZohoBookkeeperApp"
                ]),
                sources: sources,
                resources: resources,
                dependencies: dependencies
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            settings: .settings(base: Constants.sharedSettings),
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
