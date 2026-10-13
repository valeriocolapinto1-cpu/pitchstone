#if canImport(Network) && canImport(Security)
import Foundation
import Network
import PitchstoneSync
import Security

/// Service token di Access nel Keychain, solo su questo dispositivo.
public enum AccessKeychain {
    private static let service = "app.pitchstone.access"

    public static func load() -> AccessCredentials? {
        guard let id = read("client-id"), let secret = read("client-secret") else { return nil }
        return AccessCredentials(clientID: id, clientSecret: secret)
    }

    public static func save(_ credentials: AccessCredentials) throws {
        try write("client-id", credentials.clientID)
        try write("client-secret", credentials.clientSecret)
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: String, _ value: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Avvia la sync quando la rete torna disponibile, così le modifiche fatte
/// offline partono da sole.
@MainActor
public final class AutoSync {
    private let engine: SyncEngine
    private let monitor = NWPathMonitor()
    private var online = false

    public init(engine: SyncEngine) {
        self.engine = engine
    }

    public func start() {
        // Chiamato sulla coda di rete: la closure non deve ereditare il MainActor.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.update(online: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.pitchstone.network"))
    }

    public func stop() {
        monitor.cancel()
    }

    /// Da chiamare dopo una modifica locale o al ritorno in primo piano.
    public func syncNow() {
        guard online else { return }
        Task { await engine.sync() }
    }

    private func update(online: Bool) {
        let cameBack = online && !self.online
        self.online = online
        if cameBack { syncNow() }
    }
}
#endif
