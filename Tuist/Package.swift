// swift-tools-version: 5.9
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        "SwiftAnthropic": .framework,
        "ArgumentParser": .framework,
        "ZohoBooksClient": .framework,
    ]
)
#endif

let package = Package(
    name: "Dependencies",
    dependencies: [
        .package(path: "../../ZohoBooksClient"),
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
    ]
)
