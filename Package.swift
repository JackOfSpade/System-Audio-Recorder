// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TapDeck",
    platforms: [
        // Section 1/9: the Process Tap API requires macOS 14.2+; the design's
        // stated minimum deployment target is 14.4.
        .macOS("14.4")
    ],
    products: [
        // TapKit is intentionally NOT exposed as a product: it's consumed
        // only by tapdeck/TapDeckApp/TapKitTests within this same package.
        .executable(name: "tapdeck", targets: ["tapdeck"]),
        .executable(name: "TapDeckApp", targets: ["TapDeckApp"])
    ],
    targets: [
        // C11 static library: lock-free SPSC ring buffer + real-time capture context.
        // Depends on libc only. No Swift runtime anywhere near this target.
        .target(
            name: "TapDeckRT",
            path: "Sources/TapDeckRT",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-std=c11"])
            ]
        ),

        // All capture, device, file, watchdog, export, and trigger logic. No UI imports.
        .target(
            name: "TapKit",
            dependencies: ["TapDeckRT"],
            path: "Sources/TapKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("UserNotifications")
            ]
        ),

        // Standalone headless CLI. Own bundle id / own TCC grant via embedded Info.plist.
        // Info.plist is consumed via the __info_plist linker section (Section 9.1),
        // not as a SwiftPM resource, so it's excluded from resource processing.
        .executableTarget(
            name: "tapdeck",
            dependencies: ["TapKit"],
            path: "Sources/tapdeck",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/tapdeck/Info.plist"
                ])
            ]
        ),

        // Menu-bar-first GUI app. AppKit lifecycle + SwiftUI views. Info.plist
        // is copied into the .app bundle by a separate packaging step (an
        // Xcode app target, or a small script), not by SwiftPM — SwiftPM
        // executables don't produce .app bundles — so it's excluded here.
        .executableTarget(
            name: "TapDeckApp",
            dependencies: ["TapKit"],
            path: "Sources/TapDeckApp",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppIntents"),
                .linkedFramework("UserNotifications")
            ]
        ),

        // Pure-C ring-buffer smoke test (Tests/CRingTests): exercises
        // TapDeckRT's C API directly, with no Swift/C interop layer in
        // between, as a cross-check against RingBufferTests.swift. Wired in
        // as a real target (previously it sat unbuilt and unrun) and driven
        // from TapKitTests via `td_ring_smoke_test_run()`.
        .target(
            name: "CRingSmokeTest",
            dependencies: ["TapDeckRT"],
            path: "Tests/CRingTests",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-std=c11"])
            ]
        ),

        .testTarget(
            name: "TapKitTests",
            dependencies: ["TapKit", "TapDeckRT", "CRingSmokeTest"],
            path: "Tests/TapKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
