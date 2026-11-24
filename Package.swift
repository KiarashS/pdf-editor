// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PDFEditor",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PDFEditor", targets: ["PDFEditor"]),
        .library(name: "PDFEditorCore", targets: ["PDFEditorCore"]),
    ],
    targets: [
        .target(
            name: "PDFEditorCore",
            path: "Sources/PDFEditorCore"
        ),
        .executableTarget(
            name: "PDFEditor",
            dependencies: ["PDFEditorCore"],
            path: "Sources/PDFEditor"
        ),
        .testTarget(
            name: "PDFEditorCoreTests",
            dependencies: ["PDFEditorCore"],
            path: "Tests/PDFEditorCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
