// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LLM_chat_bot",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.64.0"),
        // Hosted-checkout gateways sign their callbacks (MD5/HMAC-SHA256), and a
        // signature check is the only thing standing between a POST from the
        // internet and a free subscription. Already in the resolved graph via
        // async-http-client, so this only surfaces the product.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // Postgres driver, not a web framework: it lives in the vapor org but
        // pulls only swift-nio / swift-log / swift-crypto, all already resolved
        // here. It buys the three things PostgREST cannot express — transactions
        // (money moves as one unit), constraints the database enforces itself,
        // and `pg_try_advisory_lock` for an honest single writer.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "LLM_chat_bot",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        // Unit tests for the pure logic: the state actor, formatters, parsers and
        // config types. Nothing here touches the network or Supabase.
        .testTarget(
            name: "LLM_chat_botTests",
            dependencies: [
                "LLM_chat_bot",
                // The end-to-end tests stand up a local Bot API stand-in with
                // the same NIO server the app itself serves /health from.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
