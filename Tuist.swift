import ProjectDescription

let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .upToNextMajor("26.0"),
        swiftVersion: "6.0"
    )
)

// Previous version that used Tuist Cloud (removed that feature to save on expenses)
//
// let tuist = Tuist(
//    fullHandle: "andrewash/ZohoAIBookkeeper",
//    project: .tuist(
//        compatibleXcodeVersions: .upToNextMajor("26.0"),
//        swiftVersion: "6.0"
//    )
// )
