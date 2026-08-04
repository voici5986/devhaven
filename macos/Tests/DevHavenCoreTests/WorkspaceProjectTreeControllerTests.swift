import XCTest
@testable import DevHavenCore

final class WorkspaceProjectTreeControllerTests: XCTestCase {
    private var rootURL: URL!
    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhaven-project-tree-controller-\(UUID().uuidString)", isDirectory: true)
        projectURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        projectURL = nil
        rootURL = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testPrepareActiveProjectTreeStateBuildsInitialState() async throws {
        try createDirectory("Sources")
        try createFile("README.md", contents: "hello")
        let normalizedProjectPath = normalizeTestPath(projectURL.path)
        let store = WorkspaceProjectTreeStateStore()
        let controller = makeController(
            store: store,
            normalizedProjectPath: normalizedProjectPath
        )

        controller.prepareActiveProjectTreeState()

        let loaded = await waitUntil(timeout: 1) {
            store.statesByProjectPath[normalizedProjectPath]?.rootNodes.count == 2
        }
        XCTAssertTrue(loaded)

        let state = try XCTUnwrap(store.statesByProjectPath[normalizedProjectPath])
        XCTAssertEqual(state.rootNodes.map(\.name).sorted(), ["README.md", "Sources"])
        XCTAssertFalse(store.refreshingProjectPaths.contains(normalizedProjectPath))
    }

    @MainActor
    func testSelectProjectTreeNodeUpdatesStateAndSyncsGitSelection() throws {
        let normalizedProjectPath = normalizeTestPath(projectURL.path)
        let selectedFilePath = normalizeTestPath(projectURL.appendingPathComponent("App.swift").path)
        var syncedSelections: [(String, String?)] = []
        let store = WorkspaceProjectTreeStateStore(
            statesByProjectPath: [
                normalizedProjectPath: WorkspaceProjectTreeState(
                    rootProjectPath: normalizedProjectPath,
                    rootNodes: [
                        WorkspaceProjectTreeNode(
                            path: selectedFilePath,
                            parentPath: normalizedProjectPath,
                            name: "App.swift",
                            kind: .file,
                            isHidden: false
                        )
                    ],
                    childrenByDirectoryPath: [normalizedProjectPath: []]
                )
            ]
        )
        let controller = makeController(
            store: store,
            normalizedProjectPath: normalizedProjectPath,
            syncGitSelection: { projectPath, selectedPath in
                syncedSelections.append((projectPath, selectedPath))
            }
        )

        controller.selectProjectTreeNode(selectedFilePath, in: normalizedProjectPath)

        XCTAssertEqual(store.statesByProjectPath[normalizedProjectPath]?.selectedPath, selectedFilePath)
        XCTAssertEqual(syncedSelections.count, 1)
        XCTAssertEqual(syncedSelections.first?.0, normalizedProjectPath)
        XCTAssertEqual(syncedSelections.first?.1, selectedFilePath)
    }

    @MainActor
    func testCollapsedDirectoryRejectsLateResultFromSupersededLoad() async throws {
        try createDirectory("Sources")
        let normalizedProjectPath = normalizeTestPath(projectURL.path)
        let sourcesPath = normalizeTestPath(projectURL.appendingPathComponent("Sources", isDirectory: true).path)
        let stalePath = normalizeTestPath(projectURL.appendingPathComponent("Sources/Stale.swift").path)
        let freshPath = normalizeTestPath(projectURL.appendingPathComponent("Sources/Fresh.swift").path)
        let sourcesNode = WorkspaceProjectTreeNode(
            path: sourcesPath,
            parentPath: normalizedProjectPath,
            name: "Sources",
            kind: .directory,
            isHidden: false
        )
        let store = WorkspaceProjectTreeStateStore(
            statesByProjectPath: [
                normalizedProjectPath: WorkspaceProjectTreeState(
                    rootProjectPath: normalizedProjectPath,
                    rootNodes: [sourcesNode],
                    childrenByDirectoryPath: [normalizedProjectPath: [sourcesNode]]
                )
            ]
        )
        let loader = ControlledDirectoryLoader(
            staleResult: [
                WorkspaceProjectTreeNode(
                    path: stalePath,
                    parentPath: sourcesPath,
                    name: "Stale.swift",
                    kind: .file,
                    isHidden: false
                )
            ],
            freshResult: [
                WorkspaceProjectTreeNode(
                    path: freshPath,
                    parentPath: sourcesPath,
                    name: "Fresh.swift",
                    kind: .file,
                    isHidden: false
                )
            ]
        )
        let controller = makeController(
            store: store,
            normalizedProjectPath: normalizedProjectPath,
            listDirectory: { path in try loader.load(path) }
        )

        controller.toggleDirectory(sourcesPath, in: normalizedProjectPath)
        let staleLoadStarted = await waitUntil(timeout: 1) { loader.callCount == 1 }
        XCTAssertTrue(staleLoadStarted)

        controller.toggleDirectory(sourcesPath, in: normalizedProjectPath)
        controller.toggleDirectory(sourcesPath, in: normalizedProjectPath)

        let freshLoadFinished = await waitUntil(timeout: 1) {
            store.statesByProjectPath[normalizedProjectPath]?
                .childrenByDirectoryPath[sourcesPath]?
                .map(\.name) == ["Fresh.swift"]
        }
        XCTAssertTrue(freshLoadFinished)

        loader.releaseStaleLoad()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            store.statesByProjectPath[normalizedProjectPath]?
                .childrenByDirectoryPath[sourcesPath]?
                .map(\.name),
            ["Fresh.swift"]
        )
        XCTAssertFalse(store.statesByProjectPath[normalizedProjectPath]?.loadingDirectoryPaths.contains(sourcesPath) ?? true)
    }

    @MainActor
    func testCollapsedJavaSourceRootRejectsLatePreloadResult() async throws {
        let fixture = try makeJavaPreloadFixture()
        let store = WorkspaceProjectTreeStateStore(
            statesByProjectPath: [fixture.projectPath: fixture.initialState]
        )
        let loader = ControlledDirectoryLoader(
            staleResult: [fixture.staleFile],
            freshResult: [fixture.freshFile]
        )
        defer { loader.releaseStaleLoad() }
        let controller = makeController(
            store: store,
            normalizedProjectPath: fixture.projectPath,
            listDirectory: { path in try loader.load(path) }
        )

        controller.toggleDirectory(fixture.javaPath, in: fixture.projectPath)
        let stalePreloadStarted = await waitUntil(timeout: 1) { loader.callCount == 1 }
        XCTAssertTrue(stalePreloadStarted)

        controller.toggleDirectory(fixture.javaPath, in: fixture.projectPath)
        controller.toggleDirectory(fixture.javaPath, in: fixture.projectPath)

        let freshPreloadFinished = await waitUntil(timeout: 1) {
            store.statesByProjectPath[fixture.projectPath]?
                .childrenByDirectoryPath[fixture.comPath] == [fixture.freshFile]
        }
        XCTAssertTrue(freshPreloadFinished)

        loader.releaseStaleLoad()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            store.statesByProjectPath[fixture.projectPath]?
                .childrenByDirectoryPath[fixture.comPath],
            [fixture.freshFile]
        )
    }

    @MainActor
    func testRefreshRejectsLateJavaPackagePreloadResult() async throws {
        let fixture = try makeJavaPreloadFixture()
        try "class Fresh {}".write(
            to: URL(fileURLWithPath: fixture.freshFile.path),
            atomically: true,
            encoding: .utf8
        )
        let store = WorkspaceProjectTreeStateStore(
            statesByProjectPath: [fixture.projectPath: fixture.initialState]
        )
        let loader = ControlledDirectoryLoader(
            staleResult: [fixture.staleFile],
            freshResult: [fixture.freshFile]
        )
        defer { loader.releaseStaleLoad() }
        let controller = makeController(
            store: store,
            normalizedProjectPath: fixture.projectPath,
            listDirectory: { path in try loader.load(path) }
        )

        controller.toggleDirectory(fixture.javaPath, in: fixture.projectPath)
        let stalePreloadStarted = await waitUntil(timeout: 1) { loader.callCount == 1 }
        XCTAssertTrue(stalePreloadStarted)

        controller.refreshProjectTree(for: fixture.projectPath)
        let refreshFinished = await waitUntil(timeout: 1) {
            !store.refreshingProjectPaths.contains(fixture.projectPath)
                && store.statesByProjectPath[fixture.projectPath]?
                    .childrenByDirectoryPath[fixture.comPath] == [fixture.freshFile]
        }
        XCTAssertTrue(refreshFinished)

        loader.releaseStaleLoad()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            store.statesByProjectPath[fixture.projectPath]?
                .childrenByDirectoryPath[fixture.comPath],
            [fixture.freshFile]
        )
    }

    @MainActor
    func testProjectCloseInvalidationRejectsPreloadFromPreviousState() async throws {
        let fixture = try makeJavaPreloadFixture()
        let store = WorkspaceProjectTreeStateStore(
            statesByProjectPath: [fixture.projectPath: fixture.initialState]
        )
        let loader = ControlledDirectoryLoader(
            staleResult: [fixture.staleFile],
            freshResult: [fixture.freshFile]
        )
        defer { loader.releaseStaleLoad() }
        let controller = makeController(
            store: store,
            normalizedProjectPath: fixture.projectPath,
            listDirectory: { path in try loader.load(path) }
        )

        controller.toggleDirectory(fixture.javaPath, in: fixture.projectPath)
        let stalePreloadStarted = await waitUntil(timeout: 1) { loader.callCount == 1 }
        XCTAssertTrue(stalePreloadStarted)

        controller.cancelDirectoryLoads(for: fixture.projectPath)
        var reopenedState = fixture.initialState
        reopenedState.expandedDirectoryPaths = [fixture.javaPath]
        reopenedState.childrenByDirectoryPath[fixture.comPath] = [fixture.freshFile]
        store.statesByProjectPath[fixture.projectPath] = reopenedState

        loader.releaseStaleLoad()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            store.statesByProjectPath[fixture.projectPath]?
                .childrenByDirectoryPath[fixture.comPath],
            [fixture.freshFile]
        )
    }

    @MainActor
    private func makeController(
        store: WorkspaceProjectTreeStateStore,
        normalizedProjectPath: String,
        listDirectory: (@Sendable (String) throws -> [WorkspaceProjectTreeNode])? = nil,
        syncGitSelection: @escaping @MainActor (String, String?) -> Void = { _, _ in }
    ) -> WorkspaceProjectTreeController {
        WorkspaceProjectTreeController(
            stateStore: store,
            fileSystemService: WorkspaceFileSystemService(),
            listDirectory: listDirectory,
            diagnostics: .shared,
            normalizePath: { normalizeTestPath($0) },
            resolveProjectPath: { path in
                normalizeTestPath(path ?? normalizedProjectPath)
            },
            activeProjectTreeProject: {
                Project(
                    id: UUID().uuidString,
                    name: "repo",
                    path: normalizedProjectPath,
                    tags: [],
                    runConfigurations: [],
                    worktrees: [],
                    mtime: 0,
                    size: 0,
                    checksum: "checksum",
                    isGitRepository: false,
                    gitCommits: 0,
                    gitLastCommit: 0,
                    created: 0,
                    checked: 0
                )
            },
            syncGitSelection: syncGitSelection,
            reportError: { _ in }
        )
    }

    private func makeJavaPreloadFixture() throws -> JavaPreloadFixture {
        try createDirectory("src/main/java/com")
        let projectPath = normalizeTestPath(projectURL.path)
        let javaPath = normalizeTestPath(projectURL.appendingPathComponent("src/main/java").path)
        let comPath = normalizeTestPath(projectURL.appendingPathComponent("src/main/java/com").path)
        let stalePath = normalizeTestPath(projectURL.appendingPathComponent("src/main/java/com/Stale.java").path)
        let freshPath = normalizeTestPath(projectURL.appendingPathComponent("src/main/java/com/Fresh.java").path)
        let javaNode = WorkspaceProjectTreeNode(
            path: javaPath,
            parentPath: normalizeTestPath(projectURL.appendingPathComponent("src/main").path),
            name: "java",
            kind: .directory,
            isHidden: false
        )
        let comNode = WorkspaceProjectTreeNode(
            path: comPath,
            parentPath: javaPath,
            name: "com",
            kind: .directory,
            isHidden: false
        )
        let staleFile = WorkspaceProjectTreeNode(
            path: stalePath,
            parentPath: comPath,
            name: "Stale.java",
            kind: .file,
            isHidden: false
        )
        let freshFile = WorkspaceProjectTreeNode(
            path: freshPath,
            parentPath: comPath,
            name: "Fresh.java",
            kind: .file,
            isHidden: false
        )
        return JavaPreloadFixture(
            projectPath: projectPath,
            javaPath: javaPath,
            comPath: comPath,
            staleFile: staleFile,
            freshFile: freshFile,
            initialState: WorkspaceProjectTreeState(
                rootProjectPath: projectPath,
                rootNodes: [javaNode],
                childrenByDirectoryPath: [
                    projectPath: [javaNode],
                    javaPath: [comNode],
                ]
            )
        )
    }

    private func createDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func createFile(_ relativePath: String, contents: String) throws {
        try contents.write(
            to: projectURL.appendingPathComponent(relativePath),
            atomically: true,
            encoding: .utf8
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private struct JavaPreloadFixture {
    let projectPath: String
    let javaPath: String
    let comPath: String
    let staleFile: WorkspaceProjectTreeNode
    let freshFile: WorkspaceProjectTreeNode
    let initialState: WorkspaceProjectTreeState
}

private final class ControlledDirectoryLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let staleLoadGate = DispatchSemaphore(value: 0)
    private let staleResult: [WorkspaceProjectTreeNode]
    private let freshResult: [WorkspaceProjectTreeNode]
    private var storedCallCount = 0

    init(staleResult: [WorkspaceProjectTreeNode], freshResult: [WorkspaceProjectTreeNode]) {
        self.staleResult = staleResult
        self.freshResult = freshResult
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func load(_ path: String) throws -> [WorkspaceProjectTreeNode] {
        let currentCall = lock.withLock {
            storedCallCount += 1
            return storedCallCount
        }
        if currentCall == 1 {
            staleLoadGate.wait()
            return staleResult
        }
        return freshResult
    }

    func releaseStaleLoad() {
        staleLoadGate.signal()
    }
}

private func normalizeTestPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ""
    }
    var normalized = canonicalTestPath(trimmed).replacingOccurrences(of: "\\", with: "/")
    while normalized.count > 1 && normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    return normalized
}

private func canonicalTestPath(_ path: String) -> String {
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

    let canonicalAncestorPath = realpathTestPath(ancestorPath) ?? ancestorPath
    guard !trailingComponents.isEmpty else {
        return canonicalAncestorPath
    }

    return trailingComponents.reduce(canonicalAncestorPath as NSString) { partial, component in
        partial.appendingPathComponent(component) as NSString
    } as String
}

private func realpathTestPath(_ path: String) -> String? {
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
