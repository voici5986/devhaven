import Foundation

private struct WorkspaceProjectTreeDirectoryLoadResult: Sendable {
    let directoryPath: String
    let childrenByDirectoryPath: [String: [WorkspaceProjectTreeNode]]

    var directChildCount: Int {
        childrenByDirectoryPath[directoryPath]?.count ?? 0
    }

    var loadedDirectoryCount: Int {
        childrenByDirectoryPath.count
    }
}

@MainActor
final class WorkspaceProjectTreeController {
    private let stateStore: WorkspaceProjectTreeStateStore
    private let fileSystemService: WorkspaceFileSystemService
    private let listDirectory: @Sendable (String) throws -> [WorkspaceProjectTreeNode]
    private let diagnostics: WorkspaceProjectTreeDiagnostics
    private let normalizePath: @MainActor (String) -> String
    private let resolveProjectPath: @MainActor (String?) -> String?
    private let activeProjectTreeProject: @MainActor () -> Project?
    private let syncGitSelection: @MainActor (String, String?) -> Void
    private let reportError: @MainActor (String?) -> Void

    init(
        stateStore: WorkspaceProjectTreeStateStore,
        fileSystemService: WorkspaceFileSystemService,
        listDirectory: (@Sendable (String) throws -> [WorkspaceProjectTreeNode])? = nil,
        diagnostics: WorkspaceProjectTreeDiagnostics,
        normalizePath: @escaping @MainActor (String) -> String,
        resolveProjectPath: @escaping @MainActor (String?) -> String?,
        activeProjectTreeProject: @escaping @MainActor () -> Project?,
        syncGitSelection: @escaping @MainActor (String, String?) -> Void,
        reportError: @escaping @MainActor (String?) -> Void
    ) {
        self.stateStore = stateStore
        self.fileSystemService = fileSystemService
        self.listDirectory = listDirectory ?? { path in
            try fileSystemService.listDirectory(at: path)
        }
        self.diagnostics = diagnostics
        self.normalizePath = normalizePath
        self.resolveProjectPath = resolveProjectPath
        self.activeProjectTreeProject = activeProjectTreeProject
        self.syncGitSelection = syncGitSelection
        self.reportError = reportError
    }

    func displayProjection(
        for projectPath: String,
        state: WorkspaceProjectTreeState
    ) -> WorkspaceProjectTreeDisplayProjection {
        if let cache = stateStore.projectionCacheByProjectPath[projectPath],
           cache.revision == state.revision {
            return cache.projection
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let projection = state.displayProjection
        stateStore.projectionCacheByProjectPath[projectPath] = (
            revision: state.revision,
            projection: projection
        )
        diagnostics.recordProjectionBuilt(
            projectPath: projectPath,
            revision: state.revision,
            durationMs: elapsedMillisecondsSince(startTime),
            rootCount: projection.rootNodes.count,
            aliasCount: projection.aliasMap.count
        )
        return projection
    }

    func prepareActiveProjectTreeState() {
        guard let activeProjectTreeProject = activeProjectTreeProject() else {
            return
        }
        let normalizedProjectPath = normalizePath(activeProjectTreeProject.path)
        if stateStore.statesByProjectPath[normalizedProjectPath] == nil,
           !stateStore.refreshingProjectPaths.contains(normalizedProjectPath) {
            refreshProjectTree(for: normalizedProjectPath)
        }
    }

    func refreshProjectTree(for projectPath: String? = nil) {
        guard let resolvedProjectPath = resolveProjectPath(projectPath) else {
            return
        }
        scheduleRefresh(
            for: resolvedProjectPath,
            preserving: stateStore.statesByProjectPath[resolvedProjectPath]
        )
    }

    func refreshProjectTreeNode(_ path: String?, in projectPath: String? = nil) {
        guard let resolvedProjectPath = resolveProjectPath(projectPath) else {
            return
        }
        // 首版先走整棵树重建，优先保证 rename/delete/create 后路径映射与展开态一致。
        scheduleRefresh(
            for: resolvedProjectPath,
            preserving: stateStore.statesByProjectPath[resolvedProjectPath],
            preferredSelectionPath: path
        )
    }

    func refreshProjectTree(
        for projectPath: String,
        preserving state: WorkspaceProjectTreeState?,
        preferredSelectionPath: String? = nil
    ) {
        scheduleRefresh(
            for: projectPath,
            preserving: state,
            preferredSelectionPath: preferredSelectionPath
        )
    }

    func cancelDirectoryLoads(for projectPath: String) {
        invalidateDirectoryLoads(for: normalizePath(projectPath))
    }

    func selectProjectTreeNode(_ path: String?, in projectPath: String? = nil) {
        guard let resolvedProjectPath = resolveProjectPath(projectPath),
              var state = stateStore.statesByProjectPath[resolvedProjectPath]
        else {
            return
        }
        state.selectedPath = state.canonicalDisplayPath(for: path)
        stateStore.statesByProjectPath[resolvedProjectPath] = state
        syncGitSelection(resolvedProjectPath, state.selectedPath)
    }

    func toggleDirectory(_ directoryPath: String, in projectPath: String? = nil) {
        guard let resolvedProjectPath = resolveProjectPath(projectPath),
              var state = stateStore.statesByProjectPath[resolvedProjectPath]
        else {
            return
        }

        let projection = displayProjection(for: resolvedProjectPath, state: state)
        let normalizedDirectoryPath = projection.aliasMap[normalizePath(directoryPath)]
            ?? normalizePath(directoryPath)

        if state.expandedDirectoryPaths.contains(normalizedDirectoryPath) {
            invalidateDirectoryLoad(
                projectPath: resolvedProjectPath,
                directoryPath: normalizedDirectoryPath
            )
            state.expandedDirectoryPaths.remove(normalizedDirectoryPath)
            state.loadingDirectoryPaths.remove(normalizedDirectoryPath)
            stateStore.statesByProjectPath[resolvedProjectPath] = state
            diagnostics.recordDirectoryCollapsed(
                projectPath: resolvedProjectPath,
                directoryPath: normalizedDirectoryPath,
                revision: state.revision,
                expandedCount: state.expandedDirectoryPaths.count
            )
            return
        }

        state.expandedDirectoryPaths.insert(normalizedDirectoryPath)
        if let existingChildren = state.childrenByDirectoryPath[normalizedDirectoryPath] {
            state.errorMessage = nil
            stateStore.statesByProjectPath[resolvedProjectPath] = state.canonicalizedForDisplay()
            reportError(nil)
            preloadVisibleChainsIfNeeded(
                for: normalizedDirectoryPath,
                projectRootPath: resolvedProjectPath,
                children: existingChildren
            )
            return
        }

        state.loadingDirectoryPaths.insert(normalizedDirectoryPath)
        state.errorMessage = nil
        let loadingRevision = state.revision
        stateStore.statesByProjectPath[resolvedProjectPath] = state
        reportError(nil)
        diagnostics.recordDirectoryLoadStarted(
            projectPath: resolvedProjectPath,
            directoryPath: normalizedDirectoryPath,
            revision: loadingRevision
        )

        let projectRootPath = resolvedProjectPath
        let listDirectory = listDirectory
        let loadKey = WorkspaceProjectTreeDirectoryLoadKey(
            projectPath: resolvedProjectPath,
            directoryPath: normalizedDirectoryPath
        )
        stateStore.directoryLoadTasksByKey[loadKey]?.cancel()
        let loadGeneration = (stateStore.directoryLoadGenerationByKey[loadKey] ?? 0) &+ 1
        stateStore.directoryLoadGenerationByKey[loadKey] = loadGeneration
        let startTime = ProcessInfo.processInfo.systemUptime
        stateStore.directoryLoadTasksByKey[loadKey] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try Self.loadChildrenSnapshot(
                    listDirectory: listDirectory,
                    directoryPath: normalizedDirectoryPath,
                    projectRootPath: projectRootPath
                )
                try Task.checkCancellation()
                await self?.finishDirectoryLoadSuccess(
                    for: resolvedProjectPath,
                    directoryPath: normalizedDirectoryPath,
                    generation: loadGeneration,
                    result: result,
                    startTime: startTime
                )
            } catch is CancellationError {
                return
            } catch {
                let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.finishDirectoryLoadFailure(
                    for: resolvedProjectPath,
                    directoryPath: normalizedDirectoryPath,
                    generation: loadGeneration,
                    errorDescription: errorDescription,
                    startTime: startTime
                )
            }
        }
    }

    private func finishDirectoryLoadSuccess(
        for projectPath: String,
        directoryPath: String,
        generation: Int,
        result: WorkspaceProjectTreeDirectoryLoadResult,
        startTime: TimeInterval
    ) {
        let loadKey = WorkspaceProjectTreeDirectoryLoadKey(
            projectPath: projectPath,
            directoryPath: directoryPath
        )
        guard stateStore.directoryLoadGenerationByKey[loadKey] == generation,
              var latestState = stateStore.statesByProjectPath[projectPath],
              latestState.expandedDirectoryPaths.contains(directoryPath)
        else {
            return
        }

        stateStore.directoryLoadTasksByKey[loadKey] = nil
        latestState.loadingDirectoryPaths.remove(directoryPath)
        for (path, children) in result.childrenByDirectoryPath {
            latestState.childrenByDirectoryPath[path] = children
        }
        latestState.errorMessage = nil
        latestState.advanceStructureRevision()
        let finalizedState = latestState.canonicalizedForDisplay()
        stateStore.statesByProjectPath[projectPath] = finalizedState
        reportError(nil)
        diagnostics.recordDirectoryLoadFinished(
            projectPath: projectPath,
            directoryPath: directoryPath,
            revision: finalizedState.revision,
            durationMs: elapsedMillisecondsSince(startTime),
            loadedDirectoryCount: result.loadedDirectoryCount,
            directChildCount: result.directChildCount,
            status: "success",
            errorDescription: nil
        )
    }

    private func finishDirectoryLoadFailure(
        for projectPath: String,
        directoryPath: String,
        generation: Int,
        errorDescription: String,
        startTime: TimeInterval
    ) {
        let loadKey = WorkspaceProjectTreeDirectoryLoadKey(
            projectPath: projectPath,
            directoryPath: directoryPath
        )
        guard stateStore.directoryLoadGenerationByKey[loadKey] == generation,
              var latestState = stateStore.statesByProjectPath[projectPath],
              latestState.expandedDirectoryPaths.contains(directoryPath)
        else {
            return
        }

        stateStore.directoryLoadTasksByKey[loadKey] = nil
        latestState.loadingDirectoryPaths.remove(directoryPath)
        latestState.errorMessage = errorDescription
        stateStore.statesByProjectPath[projectPath] = latestState
        reportError(latestState.errorMessage)
        diagnostics.recordDirectoryLoadFinished(
            projectPath: projectPath,
            directoryPath: directoryPath,
            revision: latestState.revision,
            durationMs: elapsedMillisecondsSince(startTime),
            loadedDirectoryCount: 0,
            directChildCount: 0,
            status: "failed",
            errorDescription: latestState.errorMessage
        )
    }

    private func preloadVisibleChainsIfNeeded(
        for directoryPath: String,
        projectRootPath: String,
        children: [WorkspaceProjectTreeNode]
    ) {
        let listDirectory = listDirectory
        let startRevision = stateStore.statesByProjectPath[projectRootPath]?.revision ?? 0
        let startTime = ProcessInfo.processInfo.systemUptime
        let loadKey = WorkspaceProjectTreeDirectoryLoadKey(
            projectPath: projectRootPath,
            directoryPath: directoryPath
        )
        stateStore.directoryLoadTasksByKey[loadKey]?.cancel()
        let loadGeneration = (stateStore.directoryLoadGenerationByKey[loadKey] ?? 0) &+ 1
        stateStore.directoryLoadGenerationByKey[loadKey] = loadGeneration
        stateStore.directoryLoadTasksByKey[loadKey] = Task.detached(priority: .utility) { [weak self] in
            let result: [String: [WorkspaceProjectTreeNode]]
            do {
                result = try Self.preloadVisibleChainsSnapshot(
                    listDirectory: listDirectory,
                    children: children,
                    projectRootPath: projectRootPath
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                await self?.finishVisibleChainPreload(
                    for: projectRootPath,
                    directoryPath: directoryPath,
                    generation: loadGeneration,
                    sourceChildren: children,
                    result: nil,
                    startRevision: startRevision,
                    startTime: startTime
                )
                return
            }

            await self?.finishVisibleChainPreload(
                for: projectRootPath,
                directoryPath: directoryPath,
                generation: loadGeneration,
                sourceChildren: children,
                result: result,
                startRevision: startRevision,
                startTime: startTime
            )
        }
    }

    private func finishVisibleChainPreload(
        for projectPath: String,
        directoryPath: String,
        generation: Int,
        sourceChildren: [WorkspaceProjectTreeNode],
        result: [String: [WorkspaceProjectTreeNode]]?,
        startRevision: Int,
        startTime: TimeInterval
    ) {
        let loadKey = WorkspaceProjectTreeDirectoryLoadKey(
            projectPath: projectPath,
            directoryPath: directoryPath
        )
        guard stateStore.directoryLoadGenerationByKey[loadKey] == generation,
              var latestState = stateStore.statesByProjectPath[projectPath],
              latestState.expandedDirectoryPaths.contains(directoryPath),
              latestState.childrenByDirectoryPath[directoryPath] == sourceChildren
        else {
            return
        }

        stateStore.directoryLoadTasksByKey[loadKey] = nil
        guard let result, !result.isEmpty else {
            return
        }
        var didMerge = false
        for (path, loadedChildren) in result where latestState.childrenByDirectoryPath[path] != loadedChildren {
            latestState.childrenByDirectoryPath[path] = loadedChildren
            didMerge = true
        }
        guard didMerge else {
            return
        }
        latestState.advanceStructureRevision()
        let finalizedState = latestState.canonicalizedForDisplay()
        stateStore.statesByProjectPath[projectPath] = finalizedState
        diagnostics.recordDirectoryLoadFinished(
            projectPath: projectPath,
            directoryPath: directoryPath,
            revision: max(startRevision, finalizedState.revision),
            durationMs: elapsedMillisecondsSince(startTime),
            loadedDirectoryCount: result.count,
            directChildCount: sourceChildren.count,
            status: "success",
            errorDescription: nil
        )
    }

    private func invalidateDirectoryLoad(projectPath: String, directoryPath: String) {
        let normalizedDirectoryPath = normalizePath(directoryPath)
        let loadKeys = stateStore.directoryLoadGenerationByKey.keys.filter {
            $0.projectPath == projectPath
                && ($0.directoryPath == normalizedDirectoryPath
                    || $0.directoryPath.hasPrefix(normalizedDirectoryPath + "/"))
        }
        guard !loadKeys.isEmpty else {
            let loadKey = WorkspaceProjectTreeDirectoryLoadKey(
                projectPath: projectPath,
                directoryPath: normalizedDirectoryPath
            )
            stateStore.directoryLoadTasksByKey.removeValue(forKey: loadKey)?.cancel()
            stateStore.directoryLoadGenerationByKey[loadKey] =
                (stateStore.directoryLoadGenerationByKey[loadKey] ?? 0) &+ 1
            return
        }
        for loadKey in loadKeys {
            stateStore.directoryLoadTasksByKey.removeValue(forKey: loadKey)?.cancel()
            stateStore.directoryLoadGenerationByKey[loadKey] =
                (stateStore.directoryLoadGenerationByKey[loadKey] ?? 0) &+ 1
        }
    }

    private func invalidateDirectoryLoads(for projectPath: String) {
        let loadKeys = Set(
            stateStore.directoryLoadGenerationByKey.keys.filter { $0.projectPath == projectPath }
                + stateStore.directoryLoadTasksByKey.keys.filter { $0.projectPath == projectPath }
        )
        for loadKey in loadKeys {
            stateStore.directoryLoadTasksByKey.removeValue(forKey: loadKey)?.cancel()
            stateStore.directoryLoadGenerationByKey[loadKey] =
                (stateStore.directoryLoadGenerationByKey[loadKey] ?? 0) &+ 1
        }
    }

    private func scheduleRefresh(
        for projectPath: String,
        preserving state: WorkspaceProjectTreeState?,
        preferredSelectionPath: String? = nil
    ) {
        let normalizedProjectPath = normalizePath(projectPath)
        let nextGeneration = (stateStore.refreshGenerationByProjectPath[normalizedProjectPath] ?? 0) &+ 1
        stateStore.refreshGenerationByProjectPath[normalizedProjectPath] = nextGeneration
        stateStore.refreshingProjectPaths.insert(normalizedProjectPath)
        stateStore.refreshTasksByProjectPath[normalizedProjectPath]?.cancel()
        invalidateDirectoryLoads(for: normalizedProjectPath)

        let fileSystemService = fileSystemService
        let startTime = ProcessInfo.processInfo.systemUptime
        stateStore.refreshTasksByProjectPath[normalizedProjectPath] = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let rebuiltState = try Self.buildStateSnapshot(
                    service: fileSystemService,
                    projectPath: normalizedProjectPath,
                    preserving: state
                )
                await self?.finishRefresh(
                    for: normalizedProjectPath,
                    generation: nextGeneration,
                    rebuiltState: rebuiltState,
                    preferredSelectionPath: preferredSelectionPath,
                    startTime: startTime
                )
            } catch is CancellationError {
                await self?.finishRefreshCancellation(
                    for: normalizedProjectPath,
                    generation: nextGeneration
                )
            } catch {
                let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.finishRefreshFailure(
                    for: normalizedProjectPath,
                    generation: nextGeneration,
                    preserving: state,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func finishRefresh(
        for projectPath: String,
        generation: Int,
        rebuiltState: WorkspaceProjectTreeState,
        preferredSelectionPath: String?,
        startTime: TimeInterval
    ) {
        guard stateStore.refreshGenerationByProjectPath[projectPath] == generation else {
            return
        }

        var finalState = rebuiltState
        if let latestState = stateStore.statesByProjectPath[projectPath] {
            finalState.expandedDirectoryPaths = latestState.expandedDirectoryPaths
                .filter { normalizePath($0) != normalizePath(projectPath) }
                .filter { fileSystemService.directoryExists(at: $0) }
            finalState.loadingDirectoryPaths = latestState.loadingDirectoryPaths
            for (path, children) in latestState.childrenByDirectoryPath {
                guard normalizePath(path) != normalizePath(projectPath) else {
                    continue
                }
                finalState.childrenByDirectoryPath[path] = children
            }
            if preferredSelectionPath == nil,
               let latestSelectedPath = latestState.selectedPath,
               FileManager.default.fileExists(atPath: latestSelectedPath) {
                finalState.selectedPath = latestSelectedPath
            }
        }
        if let preferredSelectionPath {
            finalState.selectedPath = finalState.canonicalDisplayPath(for: preferredSelectionPath)
            if finalState.selectedPath == nil,
               FileManager.default.fileExists(atPath: preferredSelectionPath) {
                finalState.selectedPath = normalizePath(preferredSelectionPath)
            }
        }
        finalState = finalState.canonicalizedForDisplay()
        finalState.errorMessage = nil
        stateStore.statesByProjectPath[projectPath] = finalState
        syncGitSelection(projectPath, finalState.selectedPath)
        stateStore.refreshingProjectPaths.remove(projectPath)
        stateStore.refreshTasksByProjectPath[projectPath] = nil
        reportError(nil)
        diagnostics.recordTreeRebuilt(
            projectPath: projectPath,
            revision: finalState.revision,
            durationMs: elapsedMillisecondsSince(startTime),
            rootCount: finalState.rootNodes.count,
            expandedCount: finalState.expandedDirectoryPaths.count
        )
    }

    private func finishRefreshFailure(
        for projectPath: String,
        generation: Int,
        preserving state: WorkspaceProjectTreeState?,
        errorDescription: String
    ) {
        guard stateStore.refreshGenerationByProjectPath[projectPath] == generation else {
            return
        }

        var fallbackState = stateStore.statesByProjectPath[projectPath]
            ?? state
            ?? WorkspaceProjectTreeState(rootProjectPath: projectPath)
        fallbackState.errorMessage = errorDescription
        stateStore.statesByProjectPath[projectPath] = fallbackState
        stateStore.refreshingProjectPaths.remove(projectPath)
        stateStore.refreshTasksByProjectPath[projectPath] = nil
        reportError(fallbackState.errorMessage)
    }

    private func finishRefreshCancellation(
        for projectPath: String,
        generation: Int
    ) {
        guard stateStore.refreshGenerationByProjectPath[projectPath] == generation else {
            return
        }

        stateStore.refreshingProjectPaths.remove(projectPath)
        stateStore.refreshTasksByProjectPath[projectPath] = nil
    }

    nonisolated private static func loadChildrenSnapshot(
        listDirectory: @Sendable (String) throws -> [WorkspaceProjectTreeNode],
        directoryPath: String,
        projectRootPath: String
    ) throws -> WorkspaceProjectTreeDirectoryLoadResult {
        let normalizedDirectoryPath = normalizePathForCompare(directoryPath)
        let normalizedProjectRootPath = normalizePathForCompare(projectRootPath)
        let children = try listDirectory(normalizedDirectoryPath)
        var loadedChildrenByDirectoryPath: [String: [WorkspaceProjectTreeNode]] = [
            normalizedDirectoryPath: children
        ]

        for child in children where child.isDirectory {
            try preloadDisplayChain(
                listDirectory: listDirectory,
                startingAt: child,
                projectRootPath: normalizedProjectRootPath,
                into: &loadedChildrenByDirectoryPath
            )
        }

        return WorkspaceProjectTreeDirectoryLoadResult(
            directoryPath: normalizedDirectoryPath,
            childrenByDirectoryPath: loadedChildrenByDirectoryPath
        )
    }

    nonisolated private static func buildStateSnapshot(
        service: WorkspaceFileSystemService,
        projectPath: String,
        preserving existingState: WorkspaceProjectTreeState?
    ) throws -> WorkspaceProjectTreeState {
        let normalizedProjectPath = normalizePathForCompare(projectPath)
        var nextState = existingState ?? WorkspaceProjectTreeState(rootProjectPath: normalizedProjectPath)
        nextState.advanceStructureRevision()

        let rootNodes = try service.listDirectory(at: normalizedProjectPath)
        nextState.rootProjectPath = normalizedProjectPath
        nextState.rootNodes = rootNodes
        nextState.childrenByDirectoryPath[normalizedProjectPath] = rootNodes

        let rootProjectionChildren = try preloadVisibleChainsSnapshot(
            listDirectory: { path in try service.listDirectory(at: path) },
            children: rootNodes,
            projectRootPath: normalizedProjectPath
        )
        for (path, children) in rootProjectionChildren {
            nextState.childrenByDirectoryPath[path] = children
        }
        nextState.errorMessage = nil

        let expandedPaths = (existingState?.expandedDirectoryPaths ?? [])
            .filter { normalizePathForCompare($0) != normalizedProjectPath }
            .filter { service.directoryExists(at: $0) }

        nextState.expandedDirectoryPaths = Set(expandedPaths)
        nextState.loadingDirectoryPaths = []
        for directoryPath in expandedPaths {
            let result = try loadChildrenSnapshot(
                listDirectory: { path in try service.listDirectory(at: path) },
                directoryPath: directoryPath,
                projectRootPath: normalizedProjectPath
            )
            for (path, children) in result.childrenByDirectoryPath {
                nextState.childrenByDirectoryPath[path] = children
            }
        }

        if let selectedPath = existingState?.selectedPath,
           FileManager.default.fileExists(atPath: selectedPath) {
            nextState.selectedPath = selectedPath
        } else {
            nextState.selectedPath = nil
        }

        return nextState.canonicalizedForDisplay()
    }

    nonisolated private static func preloadVisibleChainsSnapshot(
        listDirectory: @Sendable (String) throws -> [WorkspaceProjectTreeNode],
        children: [WorkspaceProjectTreeNode],
        projectRootPath: String
    ) throws -> [String: [WorkspaceProjectTreeNode]] {
        let normalizedProjectRootPath = normalizePathForCompare(projectRootPath)
        var loadedChildrenByDirectoryPath: [String: [WorkspaceProjectTreeNode]] = [:]
        for child in children where child.isDirectory {
            try preloadDisplayChain(
                listDirectory: listDirectory,
                startingAt: child,
                projectRootPath: normalizedProjectRootPath,
                into: &loadedChildrenByDirectoryPath
            )
        }
        return loadedChildrenByDirectoryPath
    }

    nonisolated private static func preloadDisplayChain(
        listDirectory: @Sendable (String) throws -> [WorkspaceProjectTreeNode],
        startingAt node: WorkspaceProjectTreeNode,
        projectRootPath: String,
        into loadedChildrenByDirectoryPath: inout [String: [WorkspaceProjectTreeNode]]
    ) throws {
        guard let sourceRootPath = WorkspaceProjectTreeJavaPackageSupport.javaSourceRoot(
            for: node.path,
            projectRootPath: projectRootPath
        ),
        normalizePathForCompare(node.path) != normalizePathForCompare(sourceRootPath),
        WorkspaceProjectTreeJavaPackageSupport.isPackageDirectoryPath(node.path, within: sourceRootPath)
        else {
            return
        }

        var currentNode = node
        while true {
            let currentPath = normalizePathForCompare(currentNode.path)
            let children = try listDirectory(currentPath)
            loadedChildrenByDirectoryPath[currentPath] = children
            guard let nextNode = WorkspaceProjectTreeJavaPackageSupport.compactedChildDirectory(
                children: children,
                sourceRootPath: sourceRootPath
            ) else {
                return
            }
            currentNode = nextNode
        }
    }
}

private func elapsedMillisecondsSince(_ startTime: TimeInterval) -> Int {
    max(0, Int(((ProcessInfo.processInfo.systemUptime - startTime) * 1000).rounded()))
}

private func normalizePathForCompare(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ""
    }
    var normalized = canonicalPathForFileSystemCompare(trimmed)
        .replacingOccurrences(of: "\\", with: "/")
    while normalized.count > 1 && normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    return normalized
}

private func canonicalPathForFileSystemCompare(_ path: String) -> String {
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let fileManager = FileManager.default
    var ancestorPath = standardizedPath
    var trailingComponents = [String]()

    while ancestorPath != "/", !fileManager.fileExists(atPath: ancestorPath) {
        let lastComponent = (ancestorPath as NSString).lastPathComponent
        guard !lastComponent.isEmpty else {
            break
        }
        trailingComponents.insert(lastComponent, at: 0)
        ancestorPath = (ancestorPath as NSString).deletingLastPathComponent
        if ancestorPath.isEmpty {
            ancestorPath = "/"
            break
        }
    }

    let canonicalAncestorPath = realpathString(ancestorPath) ?? ancestorPath
    guard !trailingComponents.isEmpty else {
        return canonicalAncestorPath
    }

    return trailingComponents.reduce(canonicalAncestorPath as NSString) { partial, component in
        partial.appendingPathComponent(component) as NSString
    } as String
}

private func realpathString(_ path: String) -> String? {
    guard !path.isEmpty else {
        return nil
    }
    return path.withCString { pointer in
        guard let resolvedPointer = realpath(pointer, nil) else {
            return nil
        }
        defer { free(resolvedPointer) }
        return String(cString: resolvedPointer)
    }
}
