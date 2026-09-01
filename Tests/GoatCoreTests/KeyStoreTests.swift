import Foundation
import Testing
@testable import GoatCore

@Suite("KeyStore")
struct KeyStoreTests {
    private func makeStore() -> (KeyStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "keystore-test-\(UUID().uuidString)")
        return (KeyStore(directory: directory), directory)
    }

    @Test func roundTripsPerAccount() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.read(account: "https://a.example") == nil)
        #expect(!store.has(account: "https://a.example"))

        #expect(store.write("key-a", account: "https://a.example"))
        #expect(store.write("key-b", account: "https://b.example"))
        #expect(store.read(account: "https://a.example") == "key-a")
        #expect(store.read(account: "https://b.example") == "key-b")
        #expect(store.has(account: "https://a.example"))
    }

    @Test func deleteRemovesOnlyThatAccount() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.write("key-a", account: "a")
        store.write("key-b", account: "b")
        store.delete(account: "a")
        #expect(store.read(account: "a") == nil)
        #expect(store.read(account: "b") == "key-b")
    }

    @Test func fileIsOwnerOnly() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.write("secret", account: "a")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: "credentials.json").path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions == 0o600)
    }

    @Test func corruptFileReadsAsEmptyAndRecovers() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "credentials.json"))
        #expect(store.read(account: "a") == nil)
        #expect(store.write("key-a", account: "a"))
        #expect(store.read(account: "a") == "key-a")
    }
}
