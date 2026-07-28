// swift-tools-version:5.9
import PackageDescription

// Builds the oref algorithm as a standalone, macOS-capable module
// so the algorithm test suite can run with `swift test`
//
// This is a "shadow" package: it compiles the *existing* files in
// place rather than owning its own copy, so there is exactly one
// copy of every source file and the Xcode app target keeps
// compiling the same ones.
//
// Usage:
//   swift test                            # whole algorithm suite
//   swift test --filter IobGenerateTests  # one suite

let algorithmModels = [
    "Autosens",
    "BGTargets",
    "BasalProfileEntry",
    "BloodGlucose",
    "CarbRatios",
    "CarbsEntry",
    "Determination",
    "IOBEntry",
    "InsulinSensitivities",
    "Override",
    "Preferences",
    "PumpHistoryEvent",
    "PumpSettings",
    "TDD",
    "TempBasal",
    "TempTarget",
    "TrioCustomOrefVariables"
].map { "Models/\($0).swift" }

let algorithmHelpers = [
    "ConvenienceExtensions",
    "Decimal+Extensions",
    "Formatters",
    "JSON",
    "Rounding",
    "String+Extensions",
    "TherapySettingsUtil",
    "TimeInterval+Convenience"
].map { "Helpers/\($0).swift" }

let package = Package(
    name: "TrioAlgorithm",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Trio", targets: ["Trio"])
    ],
    targets: [
        .target(
            name: "Trio",
            path: "Trio/Sources",
            sources: [
                "APS/OpenAPSSwift",
                "APS/Extensions/DecimalExtensions.swift"
            ] + algorithmModels + algorithmHelpers,
            swiftSettings: [.define("TRIO_ALGORITHM_PACKAGE")]
        ),
        .testTarget(
            name: "OpenAPSSwiftTests",
            dependencies: ["Trio"],
            path: "TrioTests/OpenAPSSwiftTests",
            resources: [.copy("json")],
            swiftSettings: [.define("TRIO_ALGORITHM_PACKAGE")]
        )
    ]
)
