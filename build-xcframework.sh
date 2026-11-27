#!/bin/bash
# Builds IDevice.xcframework, the idevice library Package.swift links, from the idevice
# submodule: its iOS, iOS Simulator and Mac Catalyst slices, the platforms Feather builds
# for, as idevice's justfile builds them. Swift Package Manager reads the xcframework
# before Xcode builds anything, so run this first: Feather's Makefile does. It needs
# rustup and Xcode; cargo builds only what changed.
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

root="$(cd "$(dirname "$0")" && pwd)"
idevice="$root/idevice"
target="$idevice/target"

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
	aarch64-apple-ios-macabi x86_64-apple-ios-macabi

cd "$idevice/ffi"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
	IPHONEOS_DEPLOYMENT_TARGET=17.0 \
	cargo build --release --target aarch64-apple-ios --features obfuscate
for rust_target in aarch64-apple-ios-sim x86_64-apple-ios; do
	BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)" \
		cargo build --release --target "$rust_target"
done
# AWS-LC does not build for Mac Catalyst: ring instead
for rust_target in aarch64-apple-ios-macabi x86_64-apple-ios-macabi; do
	BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk macosx --show-sdk-path)" \
		cargo build --release --target "$rust_target" --no-default-features --features "ring full"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/include"
cp "$idevice/ffi/idevice.h" "$idevice/swift/include/module.modulemap" "$work/include/"
lipo -create -output "$work/idevice-ios-sim.a" \
	"$target/aarch64-apple-ios-sim/release/libidevice_ffi.a" \
	"$target/x86_64-apple-ios/release/libidevice_ffi.a"
lipo -create -output "$work/idevice-maccatalyst.a" \
	"$target/aarch64-apple-ios-macabi/release/libidevice_ffi.a" \
	"$target/x86_64-apple-ios-macabi/release/libidevice_ffi.a"
rm -rf "$root/IDevice.xcframework"
xcodebuild -create-xcframework \
	-library "$target/aarch64-apple-ios/release/libidevice_ffi.a" -headers "$work/include" \
	-library "$work/idevice-ios-sim.a" -headers "$work/include" \
	-library "$work/idevice-maccatalyst.a" -headers "$work/include" \
	-output "$root/IDevice.xcframework"
