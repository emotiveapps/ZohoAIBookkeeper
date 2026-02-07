import ProjectDescription

let tuist = Tuist(
    fullHandle: "andrewash/ZohoAIBookkeeper",
    project: .tuist(
        compatibleXcodeVersions: ["16.0", "16.1", "16.2"],
        swiftVersion: "6.0"
    )
)
