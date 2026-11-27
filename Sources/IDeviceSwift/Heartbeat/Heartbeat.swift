//
//  Heartbeat.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import Foundation
import UIKit.UIApplication
import Combine
import IDevice

// MARK: - Class
// ـ♡ﮩ٨ـ heartbeat ♪₊˚
public class HeartbeatManager {
	static public let shared = HeartbeatManager()
	
	typealias IdevicePairingFile = OpaquePointer
	typealias RpPairingFileHandle = OpaquePointer
	typealias TcpProviderHandle = OpaquePointer
	typealias AdapterHandle = OpaquePointer
	typealias RemoteServerHandle = OpaquePointer
	typealias RsdHandshakeHandle = OpaquePointer
	typealias HeartbeatClientHandle = OpaquePointer
	
	public var fileManager = FileManager.default
	var provider: TcpProviderHandle?
	public var heartbeatThread: Thread?
	
	public var sessionId: UInt32? = nil
	public let ipAddress: String = "10.7.0.1"
	public let port: UInt16 = UInt16(LOCKDOWN_PORT)
	public let port_rsd: UInt16 = UInt16(49152)
	
	public let restartLock = NSLock()
	public var isRestartInProgress = false
	public var restartBackoffTime: TimeInterval = 1.0
	public var restartWorkItem: DispatchWorkItem?
	public var firstRun = false
	
	public var cancellable: AnyCancellable? // Combine
	
	// One important note is that if a user gets `InvalidHostID -9` from heartbeat
	// we need to ask them to reimport a fresh pairingfile,
	public init() {
		#if DEBUG
		idevice_init_logger(IdeviceLogLevel.init(3), Disabled, nil)
		#endif
		
		if #available(iOS 17.4, *) {
		} else {
			// On first start, just be a normal run, on second and onwards
			// we force restart it with a different sessionid
			cancellable = NotificationCenter.default
				.publisher(for: UIApplication.willEnterForegroundNotification)
				.receive(on: DispatchQueue.main)
				.sink { notification in
					let forceRestart = self.firstRun
					self.firstRun = true
					self.start(forceRestart)
				}
		}
	}
	
	public var isRsd: Bool {
		if #available(iOS 17.4, *) {
			true
		} else {
			false
		}
	}
	
	/// Returns (idevice) pairing file path
	/// - Returns: `Documents/Feather/pairingFile.plist`
	static public func pairingFile() -> String {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("pairingFile.plist").relativePath
	}
	
	/// The RPPairing file, which iOS 17.4 and later pair with: `Documents/rpPairingFile.plist`.
	/// It is kept apart from `pairingFile()`, where Impactor writes a lockdown pairing record
	/// each time it installs the app from a computer.
	static public func rpPairingFile() -> String {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("rpPairingFile.plist").relativePath
	}
	
	public enum PairingFileKind {
		/// An RPPairing file, kept at `rpPairingFile()`
		case rpPairing
		/// A lockdown pairing record, kept at `pairingFile()`
		case lockdown
		
		public var path: String {
			switch self {
			case .rpPairing: HeartbeatManager.rpPairingFile()
			case .lockdown: HeartbeatManager.pairingFile()
			}
		}
	}
	
	/// Which kind of pairing file the file at `path` is, as idevice reads it: an RPPairing file
	/// or a lockdown pairing record. Neither throws why idevice refused it as each.
	static public func pairingFileKind(atPath path: String) throws -> PairingFileKind {
		var rpPairingFile: RpPairingFileHandle?
		guard let rpError = rp_pairing_file_read(path, &rpPairingFile) else {
			rp_pairing_file_free(rpPairingFile)
			return .rpPairing
		}
		var lockdownPairingFile: IdevicePairingFile?
		guard let lockdownError = idevice_pairing_file_read(path, &lockdownPairingFile) else {
			idevice_pairing_file_free(lockdownPairingFile)
			return .lockdown
		}
		let asRpPairing = IDeviceSwiftError(rpError, context: "as an RPPairing file")
		let asLockdown = IDeviceSwiftError(lockdownError, context: "as a lockdown pairing record")
		throw IDeviceSwiftError(message: "\(path) is not a pairing file idevice reads: \(asRpPairing.message); \(asLockdown.message)")
	}
}
