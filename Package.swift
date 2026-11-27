// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "IDeviceKit",
	platforms: [
		.iOS(.v15),
		.macOS(.v12),
	],
	products: [
		.library(
			name: "IDevice",
			targets: ["IDevice"]
		),
		.library(
			name: "IDeviceSwift",
			targets: ["IDeviceSwift"]
		),
	],
	targets: [
		// Built from the idevice submodule by build-xcframework.sh, which is to run first
		.binaryTarget(
			name: "IDevice",
			path: "IDevice.xcframework"
		),
		.target(
			name: "IDeviceSwift",
			dependencies: ["IDevice"]
		),
	]
)
