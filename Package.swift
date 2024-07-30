// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "CodeEditorView",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
    .visionOS(.v1)
  ],
  products: [
    .library(
      name: "LanguageSupport",
      targets: ["LanguageSupport"]),
    .library(
      name: "CodeEditorView",
      targets: ["CodeEditorView"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/ChimeHQ/Rearrange.git",
      .upToNextMajor(from: "1.8.1")
    ),
    .package(name: "TestStrings", path: "../TestStrings"),
  ],
  targets: [
    .target(
      name: "LanguageSupport",
      dependencies: [
        "Rearrange",
      ],
      swiftSettings: [
        .enableUpcomingFeature("BareSlashRegexLiterals")
      ]),
    .target(
      name: "CodeEditorView",
      dependencies: [
        "LanguageSupport",
        "Rearrange",
        "TestStrings"
      ]),
    .testTarget(
      name: "CodeEditorTests",
      dependencies: ["CodeEditorView"]),
  ]
)
