import Foundation
import CryptoKit

// User-defined workflow bindings.
//
// The user records a workflow in Automator ("Watch Me Do" or a composed
// Shortcut), saves the .workflow bundle anywhere on disk, then binds a
// trigger phrase to it via the CLI:
//
//     sonar-dictate bind "rotate cert" ~/Library/Workflows/Applications/RotateCert.workflow
//
// Later, when the dictation system finalizes a transcript that begins with
// the bound trigger phrase (case-insensitive prefix match), the workflow
// fires automatically via /usr/bin/automator. Anything the user said after
// the trigger phrase is passed as the workflow's input.
//
// Bindings are stored encrypted alongside recordings, under the same
// Secure Enclave-bound key. They never leave the device.

struct WorkflowBinding: Codable, Hashable {
    let id: String
    let triggerPhrase: String   // lowercased, trimmed; prefix-matched against transcripts
    let workflowPath: String    // absolute path to .workflow bundle
    let name: String
    let registeredAt: Date
}

enum WorkflowStoreError: Error, CustomStringConvertible {
    case noSuchBinding(String)
    case workflowNotFound(String)
    case automatorNotAvailable
    case duplicateTrigger(String)

    var description: String {
        switch self {
        case .noSuchBinding(let id):    return "no binding with id \(id)"
        case .workflowNotFound(let p):  return "no .workflow at \(p)"
        case .automatorNotAvailable:    return "/usr/bin/automator not found"
        case .duplicateTrigger(let p):  return "trigger phrase '\(p)' is already bound"
        }
    }
}

final class WorkflowStore {
    private static let storeFileName = "workflows.enc"
    private static let storeSalt = "__sonar_dictate_workflows__"

    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    private let storeURL: URL

    init() throws {
        // Reuse the same encrypted-store directory + Secure Enclave key as
        // SecureStore. If SecureStore has already initialized in this
        // process, the key file exists; otherwise we create it.
        let baseDir = SecureStore.baseDir
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            try FileManager.default.createDirectory(
                at: baseDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let keyURL = baseDir.appendingPathComponent("device.enclave-key")
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let rep = try Data(contentsOf: keyURL)
            self.key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: rep)
        } else {
            guard SecureEnclave.isAvailable else {
                throw SecureStoreError.secureEnclaveUnavailable
            }
            let newKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            try newKey.dataRepresentation.write(to: keyURL, options: [.completeFileProtection, .atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            self.key = newKey
        }

        self.storeURL = baseDir.appendingPathComponent(Self.storeFileName)
    }

    // MARK: - Public API

    @discardableResult
    func register(triggerPhrase: String, workflowPath: String, name: String?) throws -> WorkflowBinding {
        let absolute = ((workflowPath as NSString).expandingTildeInPath as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: absolute) else {
            throw WorkflowStoreError.workflowNotFound(absolute)
        }
        let normalized = triggerPhrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var bindings = (try? loadAll()) ?? []
        if bindings.contains(where: { $0.triggerPhrase == normalized }) {
            throw WorkflowStoreError.duplicateTrigger(normalized)
        }
        let finalName = name ?? (absolute as NSString).lastPathComponent
        let binding = WorkflowBinding(
            id: UUID().uuidString.lowercased(),
            triggerPhrase: normalized,
            workflowPath: absolute,
            name: finalName,
            registeredAt: Date()
        )
        bindings.append(binding)
        try saveAll(bindings)
        return binding
    }

    func unregister(id: String) throws {
        var bindings = try loadAll()
        guard let idx = bindings.firstIndex(where: { $0.id == id || $0.triggerPhrase == id.lowercased() }) else {
            throw WorkflowStoreError.noSuchBinding(id)
        }
        bindings.remove(at: idx)
        try saveAll(bindings)
    }

    func list() throws -> [WorkflowBinding] {
        return try loadAll().sorted { $0.triggerPhrase < $1.triggerPhrase }
    }

    // Longest-prefix match. Returns the binding whose triggerPhrase is the
    // longest case-insensitive prefix of the transcript, or nil if none.
    func match(_ transcript: String) -> WorkflowBinding? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bindings = try? loadAll() else { return nil }
        var best: WorkflowBinding?
        var bestLen = 0
        for b in bindings {
            if lower.hasPrefix(b.triggerPhrase) && b.triggerPhrase.count > bestLen {
                best = b
                bestLen = b.triggerPhrase.count
            }
        }
        return best
    }

    // Fire the workflow via /usr/bin/automator. Blocks until the workflow
    // exits; wrap in a Task at the call site for fire-and-forget UX.
    // The remainder of the user's transcript (after the trigger phrase) is
    // passed as the workflow input.
    @discardableResult
    func execute(_ binding: WorkflowBinding, input: String? = nil) throws -> Int32 {
        let automatorPath = "/usr/bin/automator"
        guard FileManager.default.isExecutableFile(atPath: automatorPath) else {
            throw WorkflowStoreError.automatorNotAvailable
        }
        guard FileManager.default.fileExists(atPath: binding.workflowPath) else {
            throw WorkflowStoreError.workflowNotFound(binding.workflowPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: automatorPath)
        if let input = input, !input.isEmpty {
            process.arguments = ["-i", input, binding.workflowPath]
        } else {
            process.arguments = [binding.workflowPath]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Encrypted persistence

    private func loadAll() throws -> [WorkflowBinding] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }
        let blob = try Data(contentsOf: storeURL)
        guard !blob.isEmpty else { return [] }
        let plain = try decrypt(blob: blob)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WorkflowBinding].self, from: plain)
    }

    private func saveAll(_ bindings: [WorkflowBinding]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(bindings)
        let blob = try encrypt(plaintext: plain)
        try blob.write(to: storeURL, options: [.completeFileProtection, .atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private func encrypt(plaintext: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(Self.storeSalt.utf8),
            sharedInfo: Data("sonar-dictate.v1.workflows".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: derived)
        guard let combined = sealed.combined else {
            throw SecureStoreError.malformedCiphertext
        }
        let pubBytes = ephemeral.publicKey.rawRepresentation
        var blob = Data()
        var len = UInt32(pubBytes.count).bigEndian
        blob.append(Data(bytes: &len, count: 4))
        blob.append(pubBytes)
        blob.append(combined)
        return blob
    }

    private func decrypt(blob: Data) throws -> Data {
        guard blob.count > 4 else { throw SecureStoreError.malformedCiphertext }
        let lenBE: UInt32 = blob.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let pubLen = Int(UInt32(bigEndian: lenBE))
        let pubEnd = 4 + pubLen
        guard blob.count > pubEnd else { throw SecureStoreError.malformedCiphertext }
        let pubBytes = blob.subdata(in: 4..<pubEnd)
        let sealedBytes = blob.subdata(in: pubEnd..<blob.count)
        let ephPub = try P256.KeyAgreement.PublicKey(rawRepresentation: pubBytes)
        let shared = try key.sharedSecretFromKeyAgreement(with: ephPub)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(Self.storeSalt.utf8),
            sharedInfo: Data("sonar-dictate.v1.workflows".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(combined: sealedBytes)
        return try AES.GCM.open(sealed, using: derived)
    }
}
