import ProjectDescription

// MARK: - Constants

public enum Constants {
    public static let organizationName = "com.emotiveapps"
    public static let developmentTeam = "M7T8YXH895"
    public static let iOSVersion = "26.0"
    public static let macOSVersion = "14.0"
    public static let watchOSVersion = "10.0"

    public static let sharedSettings: SettingsDictionary = [
        "DEVELOPMENT_TEAM": .string(developmentTeam),
        "CODE_SIGN_STYLE": "Automatic",
        "SWIFT_VERSION": "6.0",
        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        // NO so the SwiftLint script phase can read the source tree and the
        // repo-root .swiftlint.yml (the lint phase is our only build script).
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
    ]

    /// SwiftLint as a build phase, using the same mise-pinned binary and
    /// repo-root .swiftlint.yml as `just lint` and (eventually) CI — one
    /// version pin governs every surface. Skips quietly if mise isn't set up.
    public static let lintScript: TargetScript = .post(
        script: """
        export PATH="$HOME/.local/share/mise/shims:$PATH"
        if command -v swiftlint >/dev/null 2>&1; then
          swiftlint lint --config "${SRCROOT}/../../.swiftlint.yml" "${SRCROOT}/Sources"
        else
          echo "warning: SwiftLint not installed — run 'mise install' (skipping lint)"
        fi
        """,
        name: "SwiftLint",
        basedOnDependencyAnalysis: false
    )

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
        let frameworkSettings: Settings = .settings(base: [
            "CODE_SIGN_IDENTITY": "",
            "ENABLE_MODULE_VERIFIER": "YES",
            "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
        ])
        let targets: [Target] = [
            .target(
                name: name,
                destinations: destinations(for: platforms),
                product: .framework,
                bundleId: "\(Constants.organizationName).\(name)",
                deploymentTargets: deploymentTargets,
                sources: sources,
                resources: resources,
                scripts: [Constants.lintScript],
                dependencies: dependencies,
                settings: frameworkSettings
            ),
            .target(
                name: "\(name)Tests",
                destinations: destinations(for: platforms),
                product: .unitTests,
                bundleId: "\(Constants.organizationName).\(name)Tests",
                deploymentTargets: deploymentTargets,
                sources: ["Tests/**"],
                dependencies: [.target(name: name)],
                // Ad-hoc signing so `xcodebuild test` works without a Mac
                // Development certificate installed.
                settings: .settings(base: ["CODE_SIGN_IDENTITY": "-"])
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            options: .options(automaticSchemesOptions: .disabled),
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
                scripts: [Constants.lintScript],
                dependencies: dependencies
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            options: .options(automaticSchemesOptions: .disabled),
            settings: .settings(base: Constants.sharedSettings),
            targets: targets
        )
    }

    /// Configuration for an embedded share extension target.
    struct ShareExtensionSpec {
        public let name: String
        public let sources: SourceFilesList
        public let entitlements: Entitlements?

        public init(name: String, sources: SourceFilesList, entitlements: Entitlements? = nil) {
            self.name = name
            self.sources = sources
            self.entitlements = entitlements
        }
    }

    /// Configuration for an embedded companion watchOS app target.
    ///
    /// The watch target must live in the same project as the iOS app: Tuist
    /// only generates the "Embed Watch Content" phase for same-project
    /// dependencies (`directLocalTargetDependencies`). Sources may still live
    /// elsewhere in the repo via relative globs.
    struct WatchAppSpec {
        public let name: String
        public let sources: SourceFilesList
        public let resources: ResourceFileElements?
        public let entitlements: Entitlements?
        public let dependencies: [TargetDependency]
        public let widget: WatchWidgetSpec?

        public init(
            name: String,
            sources: SourceFilesList,
            resources: ResourceFileElements? = nil,
            entitlements: Entitlements? = nil,
            dependencies: [TargetDependency] = [],
            widget: WatchWidgetSpec? = nil
        ) {
            self.name = name
            self.sources = sources
            self.resources = resources
            self.entitlements = entitlements
            self.dependencies = dependencies
            self.widget = widget
        }
    }

    /// Configuration for a WidgetKit extension embedded in the watch app —
    /// complications only render from a widget extension, never from the
    /// watch app target itself.
    struct WatchWidgetSpec {
        public let name: String
        public let sources: SourceFilesList
        public let entitlements: Entitlements?

        public init(name: String, sources: SourceFilesList, entitlements: Entitlements? = nil) {
            self.name = name
            self.sources = sources
            self.entitlements = entitlements
        }
    }

    /// Creates an iOS app project
    static func app(
        name: String,
        dependencies: [TargetDependency] = [],
        sources: SourceFilesList = ["Sources/**"],
        resources: ResourceFileElements? = nil,
        entitlements: Entitlements? = nil,
        shareExtension: ShareExtensionSpec? = nil,
        watchApp: WatchAppSpec? = nil
    ) -> Project {
        var appDependencies = dependencies
        var extensionTargets: [Target] = []

        if let watchApp {
            appDependencies.append(.target(name: watchApp.name))
            // A companion watch app's bundle ID must be prefixed with the
            // iOS app's bundle ID or watchOS refuses to install it; the
            // widget extension's must be prefixed with the watch app's.
            let watchBundleId = "\(Constants.organizationName).\(name).watchkitapp"
            var watchDependencies = watchApp.dependencies

            if let widget = watchApp.widget {
                watchDependencies.append(.target(name: widget.name))
                extensionTargets.append(.target(
                    name: widget.name,
                    destinations: [.appleWatch],
                    product: .appExtension,
                    bundleId: "\(watchBundleId).widgets",
                    deploymentTargets: Constants.deploymentTargets(for: [.watchOS]),
                    infoPlist: .extendingDefault(with: [
                        "NSExtension": [
                            "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
                        ]
                    ]),
                    sources: widget.sources,
                    entitlements: widget.entitlements,
                    scripts: [Constants.lintScript]
                ))
            }

            extensionTargets.append(.target(
                name: watchApp.name,
                destinations: [.appleWatch],
                product: .app,
                bundleId: watchBundleId,
                deploymentTargets: Constants.deploymentTargets(for: [.watchOS]),
                infoPlist: .extendingDefault(with: [
                    "WKApplication": true,
                    "WKCompanionAppBundleIdentifier": "\(Constants.organizationName).\(name)"
                ]),
                sources: watchApp.sources,
                resources: watchApp.resources,
                entitlements: watchApp.entitlements,
                scripts: [Constants.lintScript],
                dependencies: watchDependencies
            ))
        }

        if let shareExtension {
            appDependencies.append(.target(name: shareExtension.name))
            extensionTargets.append(.target(
                name: shareExtension.name,
                destinations: [.iPhone, .iPad],
                product: .appExtension,
                bundleId: "\(Constants.organizationName).\(name).\(shareExtension.name)",
                deploymentTargets: Constants.deploymentTargets(for: [.iOS]),
                infoPlist: .extendingDefault(with: [
                    "CFBundleDisplayName": "Save to Bookkeeper",
                    "NSExtension": [
                        "NSExtensionPointIdentifier": "com.apple.share-services",
                        "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                        "NSExtensionAttributes": [
                            "NSExtensionActivationRule": [
                                "NSExtensionActivationSupportsImageWithMaxCount": 10,
                                "NSExtensionActivationSupportsFileWithMaxCount": 10,
                            ],
                        ],
                    ],
                ]),
                sources: shareExtension.sources,
                entitlements: shareExtension.entitlements,
                scripts: [Constants.lintScript]
            ))
        }

        let targets: [Target] = [
            .target(
                name: name,
                // .macWithiPadDesign: the iPad binary runs on Apple Silicon
                destinations: [.iPhone, .iPad, .macWithiPadDesign],
                product: .app,
                bundleId: "\(Constants.organizationName).\(name)",
                deploymentTargets: Constants.deploymentTargets(for: [.iOS]),
                infoPlist: .extendingDefault(with: [
                    "UILaunchScreen": [
                        "UIColorName": "LaunchBackground",
                        "UIImageName": "LaunchLogo",
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
                scripts: [Constants.lintScript],
                dependencies: appDependencies
            ),
            .target(
                name: "\(name)Tests",
                destinations: [.iPhone, .iPad],
                product: .unitTests,
                bundleId: "\(Constants.organizationName).\(name)Tests",
                deploymentTargets: Constants.deploymentTargets(for: [.iOS]),
                sources: ["Tests/**"],
                dependencies: [.target(name: name)],
                settings: .settings(base: ["CODE_SIGN_IDENTITY": "-"])
            )
        ]

        return Project(
            name: name,
            organizationName: Constants.organizationName,
            options: .options(automaticSchemesOptions: .disabled),
            settings: .settings(base: Constants.sharedSettings),
            targets: targets + extensionTargets
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
