import XCTest
@testable import DevHavenApp
@testable import DevHavenCore

@MainActor
final class WorkspaceTerminalCloseCoordinatorTests: XCTestCase {
    func testConfirmIfNeededClosesImmediatelyWhenNoRunningTerminalExists() {
        let evaluator = StubTerminalCloseEvaluator(requirement: .canClose)
        let prompt = RecordingTerminalClosePrompt(result: false)
        var didClose = false

        WorkspaceTerminalCloseCoordinator.confirmIfNeeded(
            evaluators: [evaluator],
            actionDescription: "关闭整个标签页",
            prompt: prompt
        ) {
            didClose = true
        }

        XCTAssertTrue(didClose)
        XCTAssertTrue(prompt.receivedDisplayTitles.isEmpty)
    }

    func testConfirmIfNeededCancelsWhenPromptRejectsRunningTerminalClose() {
        let evaluators: [any WorkspaceTerminalCloseRequirementEvaluating] = [
            StubTerminalCloseEvaluator(requirement: .canClose),
            StubTerminalCloseEvaluator(requirement: .needsConfirmation(displayTitle: "api-server")),
            StubTerminalCloseEvaluator(requirement: .needsConfirmation(displayTitle: "vite dev"))
        ]
        let prompt = RecordingTerminalClosePrompt(result: false)
        var didClose = false

        WorkspaceTerminalCloseCoordinator.confirmIfNeeded(
            evaluators: evaluators,
            actionDescription: "关闭整个窗格",
            prompt: prompt
        ) {
            didClose = true
        }

        XCTAssertFalse(didClose)
        XCTAssertEqual(prompt.receivedDisplayTitles, ["api-server", "vite dev"])
        XCTAssertEqual(prompt.receivedActionDescription, "关闭整个窗格")
    }

    func testProjectCloseCollectsRunningTerminalsFromRootAndOwnedWorktree() throws {
        let rootProjectPath = "/tmp/project"
        let worktreePath = "/tmp/project-worktree"
        let rootController = GhosttyWorkspaceController(projectPath: rootProjectPath)
        let worktreeController = GhosttyWorkspaceController(projectPath: worktreePath)
        let rootItemID = try XCTUnwrap(rootController.selectedPaneItem?.id)
        let worktreeItemID = try XCTUnwrap(worktreeController.selectedPaneItem?.id)
        let rootEvaluator = StubTerminalCloseEvaluator(
            requirement: .needsConfirmation(displayTitle: "root server")
        )
        let worktreeEvaluator = StubTerminalCloseEvaluator(
            requirement: .needsConfirmation(displayTitle: "worktree tests")
        )
        let sessions = [
            OpenWorkspaceSessionState(projectPath: rootProjectPath, controller: rootController),
            OpenWorkspaceSessionState(
                projectPath: worktreePath,
                rootProjectPath: rootProjectPath,
                controller: worktreeController
            )
        ]

        let evaluators = WorkspaceTerminalCloseCoordinator.evaluatorsForProjectClose(
            sessions: sessions,
            affectedProjectPaths: [rootProjectPath, worktreePath]
        ) { projectPath, itemID in
            switch (projectPath, itemID) {
            case (rootProjectPath, rootItemID): rootEvaluator
            case (worktreePath, worktreeItemID): worktreeEvaluator
            default: nil
            }
        }
        let prompt = RecordingTerminalClosePrompt(result: false)
        var didClose = false

        WorkspaceTerminalCloseCoordinator.confirmIfNeeded(
            evaluators: evaluators,
            actionDescription: "关闭项目",
            prompt: prompt
        ) {
            didClose = true
        }

        XCTAssertFalse(didClose)
        XCTAssertEqual(prompt.receivedDisplayTitles, ["root server", "worktree tests"])
    }

    func testProjectCloseCollectsRunningTerminalFromQuickCLISession() throws {
        let quickTerminalPath = "/tmp/quick-terminal"
        let controller = GhosttyWorkspaceController(projectPath: quickTerminalPath)
        let terminalItemID = try XCTUnwrap(controller.selectedPaneItem?.id)
        let runningEvaluator = StubTerminalCloseEvaluator(
            requirement: .needsConfirmation(displayTitle: "quick command")
        )
        let sessions = [
            OpenWorkspaceSessionState(
                projectPath: quickTerminalPath,
                controller: controller,
                isQuickTerminal: true
            )
        ]

        let evaluators = WorkspaceTerminalCloseCoordinator.evaluatorsForProjectClose(
            sessions: sessions,
            affectedProjectPaths: [quickTerminalPath]
        ) { projectPath, itemID in
            projectPath == quickTerminalPath && itemID == terminalItemID ? runningEvaluator : nil
        }
        let prompt = RecordingTerminalClosePrompt(result: false)
        var didClose = false

        WorkspaceTerminalCloseCoordinator.confirmIfNeeded(
            evaluators: evaluators,
            actionDescription: "关闭项目",
            prompt: prompt
        ) {
            didClose = true
        }

        XCTAssertFalse(didClose)
        XCTAssertEqual(prompt.receivedDisplayTitles, ["quick command"])
    }

    func testProjectCloseWithoutLoadedRunningTerminalClosesWithoutPrompt() {
        let projectPath = "/tmp/project"
        let controller = GhosttyWorkspaceController(projectPath: projectPath)
        let sessions = [
            OpenWorkspaceSessionState(projectPath: projectPath, controller: controller)
        ]

        let evaluators = WorkspaceTerminalCloseCoordinator.evaluatorsForProjectClose(
            sessions: sessions,
            affectedProjectPaths: [projectPath]
        ) { _, _ in nil }
        let prompt = RecordingTerminalClosePrompt(result: false)
        var didClose = false

        WorkspaceTerminalCloseCoordinator.confirmIfNeeded(
            evaluators: evaluators,
            actionDescription: "关闭项目",
            prompt: prompt
        ) {
            didClose = true
        }

        XCTAssertTrue(didClose)
        XCTAssertTrue(prompt.receivedDisplayTitles.isEmpty)
    }

    func testGhosttySurfaceHostModelPromptsBeforeClosingAliveProcess() {
        let prompt = RecordingTerminalClosePrompt(result: false)
        var exitCount = 0
        let model = GhosttySurfaceHostModel(
            request: WorkspaceTerminalLaunchRequest(
                projectPath: "/tmp/devhaven",
                workspaceId: "workspace:test",
                tabId: "tab:test",
                paneId: "pane:test",
                surfaceId: "surface:test",
                terminalSessionId: "session:test"
            ),
            onSurfaceExit: { exitCount += 1 },
            closePrompt: prompt
        )
        model.surfaceTitle = "pnpm dev"

        model.debugHandleCloseRequest(processAlive: true)

        XCTAssertEqual(exitCount, 0)
        XCTAssertEqual(prompt.receivedDisplayTitles, ["pnpm dev"])
        XCTAssertEqual(model.processState, GhosttySurfaceProcessState.running)
    }

    func testGhosttySurfaceHostModelClosesAfterPromptConfirmation() {
        let prompt = RecordingTerminalClosePrompt(result: true)
        var exitCount = 0
        let model = GhosttySurfaceHostModel(
            request: WorkspaceTerminalLaunchRequest(
                projectPath: "/tmp/devhaven",
                workspaceId: "workspace:test",
                tabId: "tab:test",
                paneId: "pane:test",
                surfaceId: "surface:test",
                terminalSessionId: "session:test"
            ),
            onSurfaceExit: { exitCount += 1 },
            closePrompt: prompt
        )
        model.surfaceTitle = "pnpm dev"

        model.debugHandleCloseRequest(processAlive: true)

        XCTAssertEqual(exitCount, 1)
        XCTAssertEqual(model.processState, GhosttySurfaceProcessState.exited)
    }
}

@MainActor
private final class StubTerminalCloseEvaluator: WorkspaceTerminalCloseRequirementEvaluating {
    private let requirement: WorkspaceTerminalCloseRequirement

    init(requirement: WorkspaceTerminalCloseRequirement) {
        self.requirement = requirement
    }

    func evaluateCloseRequirement(
        _ completion: @escaping (WorkspaceTerminalCloseRequirement) -> Void
    ) {
        completion(requirement)
    }
}

@MainActor
private final class RecordingTerminalClosePrompt: WorkspaceTerminalClosePrompting {
    let result: Bool
    private(set) var receivedDisplayTitles: [String] = []
    private(set) var receivedActionDescription: String?

    init(result: Bool) {
        self.result = result
    }

    func confirmCloseTerminals(
        displayTitles: [String],
        actionDescription: String
    ) -> Bool {
        receivedDisplayTitles = displayTitles
        receivedActionDescription = actionDescription
        return result
    }
}
