import ProjectDescription

let tuist = Tuist(
    fullHandle: "andrewash/ZohoAIBookkeeper",
    project: .tuist(
        compatibleXcodeVersions: .upToNextMajor("26.0"),
        swiftVersion: "6.0"
    )
)
