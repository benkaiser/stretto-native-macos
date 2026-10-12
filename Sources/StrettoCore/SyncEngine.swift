import Foundation

public struct SyncConflict: Identifiable, Sendable {
    public let id = UUID()
    public let local: Library
    public let remote: Library
    public init(local: Library, remote: Library) { self.local = local; self.remote = remote }
}

public enum SyncResult: Sendable {
    case synced(LocalState)
    case conflict(SyncConflict)
}

public enum SyncEngine {
    public static func sync(_ state: LocalState, transport: any LibraryTransport) async throws -> SyncResult {
        let remoteVersion = try await transport.latestVersion()
        if state.dirty {
            if remoteVersion != -1 && (state.base == nil || remoteVersion != state.library.version) {
                return .conflict(SyncConflict(local: state.library, remote: try await transport.latestData()))
            }
            var upload = state.library
            upload.version = remoteVersion
            do {
                upload.version = try await transport.upload(upload)
                return .synced(LocalState(library: upload, base: upload))
            } catch StrettoError.conflict {
                return .conflict(SyncConflict(local: state.library, remote: try await transport.latestData()))
            }
        }
        if remoteVersion != state.library.version || state.base == nil {
            if remoteVersion == -1 && state.library.songs.isEmpty && state.library.playlists.isEmpty {
                let empty = Library(version: -1)
                return .synced(LocalState(library: empty, base: empty))
            }
            let library = try await transport.latestData()
            return .synced(LocalState(library: library, base: library))
        }
        return .synced(state)
    }

    public static func resolve(_ conflict: SyncConflict, useLocal: Bool, transport: any LibraryTransport) async throws -> LocalState {
        if !useLocal { return LocalState(library: conflict.remote, base: conflict.remote) }
        var library = conflict.local
        library.version = conflict.remote.version
        library.version = try await transport.upload(library)
        return LocalState(library: library, base: library)
    }
}
