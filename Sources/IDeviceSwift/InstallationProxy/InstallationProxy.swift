//
//  ConduitInstaller.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import Foundation
import SwiftUI
import IDevice
import OSLog
import UIKit.UIApplication

/// Seconds since `start`, for the installer's timings
private func seconds(since start: DispatchTime) -> Double {
	Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
}

private func megabytes(_ bytes: Int) -> Double {
	Double(bytes) / 1_048_576
}

public class InstallationProxy: Identifiable, ObservableObject {
	private let _heartbeat = HeartbeatManager.shared
	private let _uuid = UUID().uuidString
	
	typealias AfcClientHandle = OpaquePointer
	typealias AfcFileHandle = OpaquePointer
	typealias InstallationProxyClientHandle = OpaquePointer
	
	@ObservedObject
	public var viewModel: InstallerStatusViewModel
	
	public init(viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
	}
	
	/// Installs an .ipa, or an app bundle (a .app directory) the way Xcode and Impactor do: the
	/// bundle's files uploaded as they are and upgraded with PackageType Developer. iOS replaces
	/// a running app for a Developer install; for an .ipa, a Customer install, it waits until
	/// it may terminate the app, which one running in the background can put off for good.
	public func install(at url: URL, suspend: Bool = false) async throws {
		var afcClient: AfcClientHandle?
		var fileHandle: AfcFileHandle?
		var installproxy: InstallationProxyClientHandle?
		
		try await Task.detached(priority: .utility) {
			if await self._heartbeat.isRsd {
				try await self._heartbeat.ensureRSDTunnel()
			} else {
				guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
				guard await self._heartbeat.checkSocketConnection().isConnected else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
			}
			
			defer {
				afc_client_free(afcClient)
				installation_proxy_client_free(installproxy)
			}
			
			let heartbeat = await self._heartbeat
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}
	
				guard afc_client_connect_rsd(adapter, handshake, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				
				guard afc_client_connect(provider, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			}
			
			let stagingDir = "PublicStaging"
			
			let afc_make_directory_result =  afc_make_directory(afcClient, stagingDir)
			guard afc_make_directory_result == nil else {
				throw IDeviceSwiftError(afc_make_directory_result)
			}
			
			let isAppBundle = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
			let remoteDir = isAppBundle
				? "/\(stagingDir)/\(self._uuid)/\(url.lastPathComponent)"
				: "/\(stagingDir)/\(self._uuid).ipa"
			
			if isAppBundle {
				try await self._updateStatus(with: .sendingPayload)
				try await self._upload(bundle: url, to: remoteDir, with: afcClient)
			} else {
				let afc_file_open_result = afc_file_open(afcClient, remoteDir, AfcWrOnly, &fileHandle)
				guard afc_file_open_result == nil else {
					throw IDeviceSwiftError(afc_file_open_result)
				}
			
				try await self._updateStatus(with: .sendingPayload)
			
				guard let fileHandle = fileHandle else {
					throw IDeviceSwiftError(message: "Missing File Handle")
				}
			
				let data = try Data(contentsOf: url)
				let totalSize = data.count
				let chunkSize = 64 * 1024 * 1024 // 67mb
				var totalBytesWritten = 0
			
				guard let rawBuffer = data.withUnsafeBytes({ $0.baseAddress })?.assumingMemoryBound(to: UInt8.self) else {
					throw IDeviceSwiftError(message: "Error writing to AFC")
				}
			
				while totalBytesWritten < totalSize {
					let bytesLeft = totalSize - totalBytesWritten
					let bytesToWrite = min(chunkSize, bytesLeft)
					let writePtr = rawBuffer.advanced(by: totalBytesWritten)
				
					let result = afc_file_write(fileHandle, writePtr, bytesToWrite)
					if result != nil {
						throw IDeviceSwiftError(result)
					}
				
					totalBytesWritten += bytesToWrite
				
					let progress = Double(totalBytesWritten) / Double(totalSize)
					try await self._updateUploadProgress(with: progress)
				}
			
				let afc_file_close_result = afc_file_close(fileHandle)
				guard afc_file_close_result == nil else {
					throw IDeviceSwiftError(afc_file_close_result)
				}
			}
			
			try await self._updateStatus(with: .installing)
			
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}
				
				let installation_proxy_connect_rsd_result = installation_proxy_connect_rsd(adapter, handshake, &installproxy)
				guard installation_proxy_connect_rsd_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_rsd_result)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				let installation_proxy_connect_result = installation_proxy_connect(provider, &installproxy)
				guard installation_proxy_connect_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_result)
				}
			}
			
			let installStart = DispatchTime.now()
			let developerOptions = plist_new_dict()
			plist_dict_set_item(developerOptions, "PackageType", plist_new_string("Developer"))
			defer { plist_free(developerOptions) }
			
			let installError: UnsafeMutablePointer<IdeviceFfiError>? = remoteDir.withCString { cString in
				let context = Unmanaged.passUnretained(self).toOpaque()
				
				if suspend {
					DispatchQueue.main.async {
						UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
					}
				}
				
				if isAppBundle {
					return installation_proxy_upgrade_with_callback(
						installproxy,
						cString,
						developerOptions,
						Self._installationProgressCallback,
						context
					)
				}
				return installation_proxy_install_with_callback(
					installproxy,
					cString,
					nil, // options
					Self._installationProgressCallback,
					context
				)
			}
			
			guard installError == nil else {
				throw IDeviceSwiftError(installError)
			}
			Logger.installer.info("installd took \(seconds(since: installStart), format: .fixed(precision: 1), privacy: .public) s")
			
			try await Task.sleep(nanoseconds: 350_000_000)
			try await self._updateStatus(with: .completed(.success(())))
		}.value
	}
	
	/// Uploads an app bundle's directories and files to `remotePath`, the files in chunks. A
	/// bundle holds directories and regular files only; anything else stops the upload.
	private func _upload(bundle: URL, to remotePath: String, with afcClient: AfcClientHandle?) async throws {
		var entries: [(url: URL, remote: String, isDirectory: Bool, size: Int)] = []
		// Directories come before what they hold
		for relative in try FileManager.default.subpathsOfDirectory(atPath: bundle.path) {
			let item = bundle.appendingPathComponent(relative)
			let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
			if values.isDirectory == true {
				entries.append((item, "\(remotePath)/\(relative)", true, 0))
			} else if values.isRegularFile == true {
				entries.append((item, "\(remotePath)/\(relative)", false, values.fileSize!))
			} else {
				throw IDeviceSwiftError(message: "\(item.path) is neither a directory nor a regular file")
			}
		}
		
		for directory in [remotePath.components(separatedBy: "/").dropLast().joined(separator: "/"), remotePath] {
			if let error = afc_make_directory(afcClient, directory) {
				throw IDeviceSwiftError(error, context: "Cannot make \(directory)")
			}
		}
		
		let totalSize = entries.reduce(0) { $0 + $1.size }
		let chunkSize = 16 * 1024 * 1024
		var totalBytesWritten = 0
		let uploadStart = DispatchTime.now()
		for entry in entries {
			if entry.isDirectory {
				if let error = afc_make_directory(afcClient, entry.remote) {
					throw IDeviceSwiftError(error, context: "Cannot make \(entry.remote)")
				}
				continue
			}
			var fileHandle: AfcFileHandle?
			if let error = afc_file_open(afcClient, entry.remote, AfcWrOnly, &fileHandle) {
				throw IDeviceSwiftError(error, context: "Cannot open \(entry.remote)")
			}
			let local = try FileHandle(forReadingFrom: entry.url)
			while let chunk = try local.read(upToCount: chunkSize), !chunk.isEmpty {
				let error = chunk.withUnsafeBytes {
					afc_file_write(fileHandle, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count)
				}
				if let error {
					throw IDeviceSwiftError(error, context: "Cannot write \(entry.remote)")
				}
				totalBytesWritten += chunk.count
				try await self._updateUploadProgress(with: Double(totalBytesWritten) / Double(totalSize))
			}
			// Also where an error status of the last writes comes back: they are answered late
			if let error = afc_file_close(fileHandle) {
				throw IDeviceSwiftError(error, context: "Cannot close \(entry.remote)")
			}
		}
		let total = seconds(since: uploadStart)
		let files = entries.filter { !$0.isDirectory }.count
		Logger.installer.info("Uploaded \(files, privacy: .public) files and \(entries.count - files, privacy: .public) directories, \(megabytes(totalBytesWritten), format: .fixed(precision: 1), privacy: .public) MB in \(total, format: .fixed(precision: 1), privacy: .public) s (\(megabytes(totalBytesWritten) / total, format: .fixed(precision: 1), privacy: .public) MB/s)")
	}
	
	private func _updateStatus(with status: InstallerStatusViewModel.InstallerStatus) async throws {
		await MainActor.run {
			self.viewModel.status = status
		}
	}
	
	private func _updateUploadProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.uploadProgress = status
		}
	}
	
	nonisolated static private let _installationProgressCallback: @convention(c) (
		UInt64,
		UnsafeMutableRawPointer?
	) -> Void = { progress, context in
		guard let context = context else { return }
		let installer = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
		Task {
			try? await installer._updateInstallProgress(with: Double(progress) / 100.0)
		}
	}
	
	private func _updateInstallProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.installProgress = status
		}
	}
}
