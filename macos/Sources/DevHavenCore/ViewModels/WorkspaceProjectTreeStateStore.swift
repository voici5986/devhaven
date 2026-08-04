import Foundation
import Observation

struct WorkspaceProjectTreeDirectoryLoadKey: Hashable, Sendable {
    let projectPath: String
    let directoryPath: String
}

@MainActor
@Observable
final class WorkspaceProjectTreeStateStore {
    var statesByProjectPath: [String: WorkspaceProjectTreeState]
    var refreshingProjectPaths: Set<String>
    @ObservationIgnored var refreshTasksByProjectPath: [String: Task<Void, Never>]
    @ObservationIgnored var refreshGenerationByProjectPath: [String: Int]
    @ObservationIgnored var directoryLoadTasksByKey: [WorkspaceProjectTreeDirectoryLoadKey: Task<Void, Never>]
    @ObservationIgnored var directoryLoadGenerationByKey: [WorkspaceProjectTreeDirectoryLoadKey: Int]
    @ObservationIgnored var projectionCacheByProjectPath: [String: (revision: Int, projection: WorkspaceProjectTreeDisplayProjection)]

    init(
        statesByProjectPath: [String: WorkspaceProjectTreeState] = [:],
        refreshingProjectPaths: Set<String> = [],
        refreshTasksByProjectPath: [String: Task<Void, Never>] = [:],
        refreshGenerationByProjectPath: [String: Int] = [:],
        directoryLoadTasksByKey: [WorkspaceProjectTreeDirectoryLoadKey: Task<Void, Never>] = [:],
        directoryLoadGenerationByKey: [WorkspaceProjectTreeDirectoryLoadKey: Int] = [:],
        projectionCacheByProjectPath: [String: (revision: Int, projection: WorkspaceProjectTreeDisplayProjection)] = [:]
    ) {
        self.statesByProjectPath = statesByProjectPath
        self.refreshingProjectPaths = refreshingProjectPaths
        self.refreshTasksByProjectPath = refreshTasksByProjectPath
        self.refreshGenerationByProjectPath = refreshGenerationByProjectPath
        self.directoryLoadTasksByKey = directoryLoadTasksByKey
        self.directoryLoadGenerationByKey = directoryLoadGenerationByKey
        self.projectionCacheByProjectPath = projectionCacheByProjectPath
    }
}
