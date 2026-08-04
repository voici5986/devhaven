import XCTest
@testable import DevHavenCore

@MainActor
final class WorkspaceRunControllerTests: XCTestCase {
    func testRunSelectedConfigurationStartsSessionAndPublishesToolbarState() throws {
        let projectPath = "/tmp/devhaven-run-controller/project"
        let session = OpenWorkspaceSessionState(
            projectPath: projectPath,
            controller: GhosttyWorkspaceController(projectPath: projectPath)
        )
        let configuration = WorkspaceRunConfiguration(
            id: "run-app",
            projectPath: projectPath,
            rootProjectPath: projectPath,
            source: .projectRunConfiguration,
            sourceID: "project-config",
            name: "Run App",
            executable: .shell(command: "npm run dev"),
            displayCommand: "npm run dev",
            workingDirectory: projectPath,
            isShared: false
        )
        let runManager = MockWorkspaceRunManager()
        var reportedErrors: [String?] = []
        let controller = makeController(
            runManager: runManager,
            activeProjectPath: { projectPath },
            openProjectPaths: { [projectPath] },
            workspaceSession: { path in
                path == projectPath ? session : nil
            },
            availableConfigurations: { _ in [configuration] },
            reportError: { reportedErrors.append($0) }
        )

        try controller.runSelectedConfiguration()

        XCTAssertEqual(runManager.startRequests.count, 1)
        XCTAssertEqual(runManager.startRequests.first?.displayCommand, "npm run dev")
        XCTAssertEqual(runManager.startRequests.first?.projectPath, projectPath)

        let consoleState = try XCTUnwrap(controller.consoleState(for: projectPath))
        XCTAssertTrue(consoleState.isVisible)
        XCTAssertEqual(consoleState.sessions.count, 1)
        XCTAssertEqual(consoleState.selectedConfigurationID, configuration.id)
        XCTAssertEqual(consoleState.selectedSession?.state, .running)
        XCTAssertEqual(controller.toolbarState(for: projectPath).selectedConfigurationID, configuration.id)
        XCTAssertNil(reportedErrors.last ?? nil)
    }

    func testRunManagerEventsUpdateDisplayBufferAndCompletionState() throws {
        let projectPath = "/tmp/devhaven-run-controller/project"
        let session = OpenWorkspaceSessionState(
            projectPath: projectPath,
            controller: GhosttyWorkspaceController(projectPath: projectPath)
        )
        let configuration = WorkspaceRunConfiguration(
            id: "tail-log",
            projectPath: projectPath,
            rootProjectPath: projectPath,
            source: .projectRunConfiguration,
            sourceID: "project-config",
            name: "Tail Log",
            executable: .shell(command: "tail -f app.log"),
            displayCommand: "tail -f app.log",
            workingDirectory: projectPath,
            isShared: false
        )
        let runManager = MockWorkspaceRunManager()
        let controller = makeController(
            runManager: runManager,
            activeProjectPath: { projectPath },
            openProjectPaths: { [projectPath] },
            workspaceSession: { path in
                path == projectPath ? session : nil
            },
            availableConfigurations: { _ in [configuration] }
        )

        try controller.runSelectedConfiguration()
        let startedSessionID = try XCTUnwrap(runManager.startRequests.first?.sessionID)

        runManager.onEvent?(.output(projectPath: projectPath, sessionID: startedSessionID, chunk: "hello\n"))
        runManager.onEvent?(.stateChanged(projectPath: projectPath, sessionID: startedSessionID, state: .completed(exitCode: 0)))

        let consoleState = try XCTUnwrap(controller.consoleState(for: projectPath))
        XCTAssertEqual(consoleState.selectedSession?.displayBuffer, "hello\n")
        XCTAssertEqual(consoleState.selectedSession?.state, .completed(exitCode: 0))
        XCTAssertNotNil(consoleState.selectedSession?.endedAt)
    }

    func testRestartWaitsForPreviousSessionTerminalStateAndCoalescesRepeatedClicks() throws {
        let projectPath = "/tmp/devhaven-run-controller/restart"
        let session = OpenWorkspaceSessionState(
            projectPath: projectPath,
            controller: GhosttyWorkspaceController(projectPath: projectPath)
        )
        let configuration = WorkspaceRunConfiguration(
            id: "run-app",
            projectPath: projectPath,
            rootProjectPath: projectPath,
            source: .projectRunConfiguration,
            sourceID: "project-config",
            name: "Run App",
            executable: .shell(command: "npm run dev"),
            displayCommand: "npm run dev",
            workingDirectory: projectPath,
            isShared: false
        )
        let runManager = MockWorkspaceRunManager()
        let controller = makeController(
            runManager: runManager,
            activeProjectPath: { projectPath },
            openProjectPaths: { [projectPath] },
            workspaceSession: { path in path == projectPath ? session : nil },
            availableConfigurations: { _ in [configuration] }
        )

        try controller.runSelectedConfiguration()
        let firstSessionID = try XCTUnwrap(runManager.startRequests.first?.sessionID)

        try controller.runSelectedConfiguration()
        try controller.runSelectedConfiguration()
        controller.stopSelectedSession(in: projectPath)

        XCTAssertEqual(runManager.startRequests.count, 1)
        XCTAssertEqual(runManager.stoppedSessionIDs, [firstSessionID])
        XCTAssertEqual(controller.consoleState(for: projectPath)?.selectedSession?.id, firstSessionID)
        XCTAssertEqual(
            controller.consoleState(for: projectPath)?.pendingRestarts.first?.configurationID,
            configuration.id
        )
        XCTAssertEqual(
            controller.toolbarState(for: projectPath).pendingRestart?.configurationID,
            configuration.id
        )
        XCTAssertFalse(controller.toolbarState(for: projectPath).canRun)
        XCTAssertFalse(controller.toolbarState(for: projectPath).canStop)

        runManager.onEvent?(.stateChanged(
            projectPath: projectPath,
            sessionID: firstSessionID,
            state: .stopped
        ))

        XCTAssertEqual(runManager.startRequests.count, 2)
        XCTAssertNotEqual(runManager.startRequests.last?.sessionID, firstSessionID)
        XCTAssertEqual(controller.consoleState(for: projectPath)?.selectedSession?.state, .running)
        XCTAssertTrue(controller.consoleState(for: projectPath)?.pendingRestarts.isEmpty == true)
        XCTAssertNil(controller.toolbarState(for: projectPath).pendingRestart)

        runManager.onEvent?(.stateChanged(
            projectPath: projectPath,
            sessionID: firstSessionID,
            state: .stopped
        ))
        XCTAssertEqual(runManager.startRequests.count, 2)
    }

    func testCancellingPendingRestartPreventsLateTerminalStateFromStartingNewSession() throws {
        let projectPath = "/tmp/devhaven-run-controller/cancel-restart"
        let session = OpenWorkspaceSessionState(
            projectPath: projectPath,
            controller: GhosttyWorkspaceController(projectPath: projectPath)
        )
        let configuration = WorkspaceRunConfiguration(
            id: "run-app",
            projectPath: projectPath,
            rootProjectPath: projectPath,
            source: .projectRunConfiguration,
            sourceID: "project-config",
            name: "Run App",
            executable: .shell(command: "npm run dev"),
            displayCommand: "npm run dev",
            workingDirectory: projectPath,
            isShared: false
        )
        let runManager = MockWorkspaceRunManager()
        let controller = makeController(
            runManager: runManager,
            activeProjectPath: { projectPath },
            openProjectPaths: { [projectPath] },
            workspaceSession: { path in path == projectPath ? session : nil },
            availableConfigurations: { _ in [configuration] }
        )

        try controller.runSelectedConfiguration()
        let firstSessionID = try XCTUnwrap(runManager.startRequests.first?.sessionID)
        try controller.runSelectedConfiguration()

        controller.cancelPendingRestart(in: projectPath)

        XCTAssertTrue(controller.consoleState(for: projectPath)?.pendingRestarts.isEmpty == true)
        XCTAssertNil(controller.toolbarState(for: projectPath).pendingRestart)

        runManager.onEvent?(.stateChanged(
            projectPath: projectPath,
            sessionID: firstSessionID,
            state: .stopped
        ))

        XCTAssertEqual(runManager.startRequests.count, 1)
        XCTAssertEqual(controller.consoleState(for: projectPath)?.selectedSession?.state, .stopped)
    }

    func testRetainConsoleStateDropsClosedProjects() throws {
        let projectA = "/tmp/devhaven-run-controller/a"
        let projectB = "/tmp/devhaven-run-controller/b"
        let sessionA = OpenWorkspaceSessionState(
            projectPath: projectA,
            controller: GhosttyWorkspaceController(projectPath: projectA)
        )
        let sessionB = OpenWorkspaceSessionState(
            projectPath: projectB,
            controller: GhosttyWorkspaceController(projectPath: projectB)
        )
        let configurationA = WorkspaceRunConfiguration(
            id: "run-a",
            projectPath: projectA,
            rootProjectPath: projectA,
            source: .projectRunConfiguration,
            sourceID: "config-a",
            name: "Run A",
            executable: .shell(command: "echo a"),
            displayCommand: "echo a",
            workingDirectory: projectA,
            isShared: false
        )
        let configurationB = WorkspaceRunConfiguration(
            id: "run-b",
            projectPath: projectB,
            rootProjectPath: projectB,
            source: .projectRunConfiguration,
            sourceID: "config-b",
            name: "Run B",
            executable: .shell(command: "echo b"),
            displayCommand: "echo b",
            workingDirectory: projectB,
            isShared: false
        )
        let runManager = MockWorkspaceRunManager()
        let activeProjectPathBox = MutableValue(projectA)
        let controller = makeController(
            runManager: runManager,
            activeProjectPath: { activeProjectPathBox.value },
            openProjectPaths: { [projectA, projectB] },
            workspaceSession: { path in
                switch path {
                case projectA:
                    return sessionA
                case projectB:
                    return sessionB
                default:
                    return nil
                }
            },
            availableConfigurations: { path in
                switch path {
                case projectA:
                    return [configurationA]
                case projectB:
                    return [configurationB]
                default:
                    return []
                }
            }
        )

        try controller.runSelectedConfiguration()
        activeProjectPathBox.value = projectB
        try controller.runSelectedConfiguration()
        let projectBSessionID = try XCTUnwrap(runManager.startRequests.last?.sessionID)
        try controller.runSelectedConfiguration()

        XCTAssertNotNil(controller.consoleState(for: projectA))
        XCTAssertNotNil(controller.consoleState(for: projectB))
        XCTAssertEqual(
            controller.consoleState(for: projectB)?.pendingRestarts.first?.stoppedSessionID,
            projectBSessionID
        )

        controller.retainConsoleState(for: [projectA])

        XCTAssertNotNil(controller.consoleState(for: projectA))
        XCTAssertNil(controller.consoleState(for: projectB))

        runManager.onEvent?(.stateChanged(
            projectPath: projectB,
            sessionID: projectBSessionID,
            state: .stopped
        ))
        XCTAssertEqual(runManager.startRequests.count, 2)
    }

    private func makeController(
        runManager: MockWorkspaceRunManager,
        activeProjectPath: @escaping @MainActor () -> String?,
        openProjectPaths: @escaping @MainActor () -> [String],
        workspaceSession: @escaping @MainActor (String) -> OpenWorkspaceSessionState?,
        availableConfigurations: @escaping @MainActor (String) -> [WorkspaceRunConfiguration],
        reportError: @escaping @MainActor (String?) -> Void = { _ in }
    ) -> WorkspaceRunController {
        WorkspaceRunController(
            runManager: runManager,
            terminalCommandRunner: { _, _ in },
            normalizePath: { $0 },
            activeProjectPath: activeProjectPath,
            openProjectPaths: openProjectPaths,
            workspaceSession: workspaceSession,
            availableConfigurations: availableConfigurations,
            reportError: reportError
        )
    }
}

@MainActor
private final class MockWorkspaceRunManager: WorkspaceRunManaging {
    var onEvent: (@MainActor @Sendable (WorkspaceRunManagerEvent) -> Void)?
    var startRequests: [WorkspaceRunStartRequest] = []
    var stoppedSessionIDs: [String] = []

    func start(_ request: WorkspaceRunStartRequest) throws -> WorkspaceRunSession {
        startRequests.append(request)
        return WorkspaceRunSession(
            id: request.sessionID,
            configurationID: request.configurationID,
            configurationName: request.configurationName,
            configurationSource: request.configurationSource,
            projectPath: request.projectPath,
            rootProjectPath: request.rootProjectPath,
            command: request.displayCommand,
            workingDirectory: request.workingDirectory,
            state: .running,
            logFilePath: "/tmp/\(request.sessionID).log",
            startedAt: Date()
        )
    }

    func stop(sessionID: String) {
        stoppedSessionIDs.append(sessionID)
    }

    func stopAll(projectPath: String) {}
}

private final class MutableValue<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
