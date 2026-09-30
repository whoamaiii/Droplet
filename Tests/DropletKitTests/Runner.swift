import Foundation
@testable import DropletKit

@main
struct TestRunner {
    @MainActor
    static func main() async {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--instance-lock-probe" {
            let lock = SingleInstanceLock()
            guard lock.acquire(at: URL(fileURLWithPath: CommandLine.arguments[2])) == .acquired else { exit(73) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            withExtendedLifetime(lock) {}
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--loopback-qa" {
            do { try await LoopbackDownloadTests().run(urlText: CommandLine.arguments[2], rootPath: CommandLine.arguments[3]) }
            catch { recordFailure("Loopback QA threw: \(error)") }
            let counts = Checks.counts
            print("Loopback QA: \(counts.assertions) assertions, \(counts.failures) failures")
            exit(counts.failures == 0 ? 0 : 1)
        }
        // Fail decisively rather than leaving an orphaned hung test run.
        alarm(60)
        let lifecycle = DownloadLifecycleTests()
        let infrastructure = InfrastructureTests()
        let processInspector = ProcessInspectorTests()
        let lines = ProcessLineBufferTests()
        let output = DownloadOutputTests()
        let workspace = DownloadWorkspaceTests()
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("Dormant fresh quota and recovery write failure", { try TrialAccountingTests().testDormantTakeoverLoadsFreshQuotaAndRecoveryFailures() }),
            ("Unreadable trial blocks starts", { TrialAccountingTests().testUnreadableTrialFactoryBlocksAllStarts() }),
            ("Done state and update exclusion", { await TrialAccountingTests().testDoneReopensAndUpdatesCannotOverlapDownloads() }),
            ("Failed and cancelled trial retries", { try await TrialAccountingTests().testTrialFailureCancelAndRetryKeepAllCredits() }),
            ("Accounting failure before and after publication", { try await TrialAccountingTests().testAccountingWriteFailureBeforeAndAfterPublication() }),
            ("Contender preserves active trial journal", { try SingleInstanceLockTests().testContenderCannotRecoverOwnersTrialJournal() }),
            ("Trial three new saves and idempotency", { try TrialAccountingTests().testThreeNewSuccessesAndIdempotentCompletion() }),
            ("Trial cancellation and existing files", { try TrialAccountingTests().testCancelledAndExistingFilesDoNotUseCredit() }),
            ("Trial crash publication reconciliation", { try TrialAccountingTests().testCrashBetweenPublicationAndAccountingRecoversExactlyOnce() }),
            ("Trial prepublication crash and corruption", { try TrialAccountingTests().testCrashBeforePublicationDoesNotUseCreditAndCorruptionFailsClosed() }),
            ("Trial process access gate", { try TrialAccountingTests().testGateBlocksProcessAfterQuotaOrUnavailableState() }),
            ("Trial unrelated files never count", { try TrialAccountingTests().testUnpublishedWitnessAndUnrelatedFileDoNotConsumeCredit() }),
            ("License evidence product, instance and expiry binding", { try LicenseClientTests().testEvidenceIsProductInstanceAndExpiryBound() }),
            ("License HTTP and cache fail closed", { try LicenseClientTests().testHTTPAndPersistedEvidenceFailClosed() }),
            ("Unconfigured licensing never grants access", { await LicenseClientTests().testUnconfiguredClientNeverGrantsAccess() }),
            ("Persisted folder and active-job protection", { try DownloadFolderTests().testFolderChoicePersistsAndInvalidChoicePreservesPrevious() }),
            ("Missing folder and explicit recovery", { try DownloadFolderTests().testUnavailableBookmarkBlocksUntilExplicitRecovery() }),
            ("Every UTF-8 split boundary", { try lines.testEveryByteBoundaryPreservesUnicodeAndRecords() }),
            ("CR LF and final line", { try lines.testCRLFAndEOFProduceNoDuplicates() }),
            ("Bounded subprocess records", { try lines.testOversizedRecordFailsBoundedly() }),
            ("Split progress and EOF error", { await lifecycle.testSplitProgressAndFinalErrorBeforeExit() }),
            ("EOF before exit and stale final line", { await lifecycle.testEOFAwaitsExitAndOldFinalLineIsIgnored() }),
            ("Structured engine events", { output.testStructuredEventsAndUnknownTotals() }),
            ("Transfer completion is not saved file", { await output.testTransferCompletionCannotFinishWithoutSavedFile() }),
            ("Saved result waits for exit", { try await output.testSavedResultWaitsForEOFAndSuccessfulExit() }),
            ("Invalid output cannot report success", { try await output.testProtocolErrorsCannotTurnIntoSuccess() }),
            ("Atomic output collision protection", { try workspace.testSameTitlePublicationNeverOverwrites() }),
            ("Reject unsafe or changed output", { try workspace.testUnsafeAndChangedOutputsAreRejected() }),
            ("Bounded Unicode filenames", { workspace.testUnicodeAndLongNamesAreBounded() }),
            ("Native verification of real media", { try await MediaVerifierTests().testRealMP4MediaAndUnsupportedCodec() }),
            ("Actionable filesystem failures", { workspace.testActionableFilesystemFailures() }),
            ("Cancel and replace during media verification", { try await FinalizationLifecycleTests().testCancelAndReplacementDuringVerification() }),
            ("Publication failures through manager", { try await FinalizationLifecycleTests().testPublicationFailuresDoNotBecomeSuccess() }),
            ("Quit flushes cancelled jobs", { try lifecycle.testQuitFlushesAllPreviouslyCancelledJobs() }),
            ("Quit cleans suspended verification", { try await FinalizationLifecycleTests().testQuitCleansSuspendedVerificationBeforeReturning() }),
            ("Public failures never import browser sessions", { await BrowserLoginTests().testPublicFailuresNeverImportBrowserSessions() }),
            ("One-download URL-bound browser consent", { try await BrowserLoginTests().testConsentIsBoundToOneURLAndDoesNotCarryToNextDownload() }),
            ("Cancel revokes browser consent", { try await BrowserLoginTests().testCancelRevokesTheConsentedRun() }),
            ("Browser consent input validation", { try BrowserLoginTests().testConsentValidatesProfileAndURL() }),
            ("Explicit child engine environment", { DownloadPolicyTests().testEngineEnvironmentIsExplicit() }),
            ("Conservative engine failure classification", { DownloadPolicyTests().testFailureClassification() }),
            ("URL validation and domain boundaries", { DownloadPolicyTests().testURLsAndDomainBoundaries() }),
            ("Explicit retry versus new clipboard link", { await DownloadPolicyTests().testExplicitRetryAndClipboardReplacement() }),
            ("Invalid input never starts engine", { DownloadPolicyTests().testInvalidInjectedURLCannotStartProcess() }),
            ("Real hanging download termination", { try await DownloadTimeoutTests().testRealHangingDownloadStopsWithoutFreezingApp() }),
            ("Fetch watchdog and stale timer", { await DownloadTimeoutTests().testFetchingTimeoutAndStaleTimer() }),
            ("Unknown-total progress and stalled transfer", { await DownloadTimeoutTests().testUnknownTotalProgressKeepsTransferAliveButRepeatedRecordDoesNot() }),
            ("Processing and total download limits", { await DownloadTimeoutTests().testProcessingAndTotalLimits() }),
            ("Quit during merge", { await lifecycle.testQuitWhileMergingClearsOnlyOwnedWork() }),
            ("Repeated start", { lifecycle.testRepeatedStartKeepsExactlyOneJob() }),
            ("Stale exit", { await lifecycle.testOldExitCannotOverwriteReplacementJob() }),
            ("Stale output", { await lifecycle.testQueuedOldOutputCannotOverwriteReplacementProgress() }),
            ("Original URL on retry", { await lifecycle.testRetryKeepsOriginalURLWhenClipboardChanges() }),
            ("Owned cancel signals", { lifecycle.testCancelDetachesPipeAndSignalsOnlyOwnedSnapshot() }),
            ("Popover while downloading", { lifecycle.testOpeningPopoverDoesNotResetActiveDownload() }),
            ("Launch failure recovery", { lifecycle.testLaunchFailureIsVisibleAndAllowsASecondAttempt() }),
            ("Shutdown clock and ownership", { lifecycle.testShutdownUsesVirtualClockAndKillsOnlyItsOwnProcessTree() }),
            ("Real version subprocess responsiveness", { try await EngineVersionProbeTests().testRealProcessRemainsResponsiveAndTimesOut() }),
            ("Version probe output and exit ordering", { await EngineVersionProbeTests().testVersionWaitsForOutputAndExit() }),
            ("Version probe timeout ownership", { await EngineVersionProbeTests().testTimeoutStopsOwnedProcessAndIgnoresLateOutput() }),
            ("Version probe rejection and cancellation", { await EngineVersionProbeTests().testInvalidOutputAndCancellation() }),
            ("Updater success and version query", { await EngineUpdaterTests().testSuccessIncludesAsynchronousVersionAndCannotOverlap() }),
            ("Updater deadline and shutdown ownership", { await EngineUpdaterTests().testTimeoutAndShutdownCleanOwnedJobsAndIgnoreOldExit() }),
            ("Updater missing executable and cancelled version", { await EngineUpdaterTests().testShutdownDuringVersionAndMissingUpdater() }),
            ("Updater isolation", { await lifecycle.testUpdaterBoundaryIsObservableAndDoesNotStartTwice() }),
            ("Missing versus corrupt state", { try infrastructure.testMissingStateAndCorruptStateAreDifferent() }),
            ("Locked store", { infrastructure.testLockedStoreIsNotMistakenForFreshState() }),
            ("Atomic write failure", { try infrastructure.testFailedWritePreservesPreviousState() }),
            ("Independent state keys", { try infrastructure.testStateKeysDoNotOverwriteEachOther() }),
            ("HTTP 503 distinction", { try await infrastructure.testHTTPErrorStatusIsNotSilentlyConvertedToSuccessfulValidation() }),
            ("Network timeout", { await infrastructure.testNetworkTimeoutIsPropagatedSeparatelyFromRejection() }),
            ("HTTPS enforcement", { await infrastructure.testHTTPTransportRejectsPlaintextBeforeSendingAnything() }),
            ("Same-origin TLS redirects", { infrastructure.testRedirectsCannotMoveCredentialsToAnotherOrigin() }),
            ("Real owned children and unrelated process", { try await ProcessOwnershipTests().testRealChildrenStopAndUnrelatedProcessSurvives() }),
            ("Cancel cleanup skips reused PIDs", { ProcessOwnershipTests().testDelayedCleanupSkipsReusedRootAndChildIDs() }),
            ("Updater cleanup skips reused PIDs", { ProcessOwnershipTests().testUpdaterCleanupSkipsReusedIDsAndQuitDoesNotRepeat() }),
            ("Unknown and actual kernel identity", { ProcessOwnershipTests().testUnknownIdentityIsNeverSignalledAndKernelIdentityMatches() }),
            ("Competing real process locks", { try await SingleInstanceLockTests().testTwoRealProcessesHaveOneOwner() }),
            ("Exclusive instance lock and release", { try SingleInstanceLockTests().testExclusiveOwnershipAndRelease() }),
            ("Instance lock rejects linked files", { try SingleInstanceLockTests().testSymlinkAndHardlinkAreRejected() }),
            ("Process tree isolation", { processInspector.testDescendantsExcludeBystandersAndRootEvenWithCycles() }),
            ("Kernel process identity", { processInspector.testActualKernelRankForThisProcessExists() }),
            ("Real subprocess and pipe", { try await processInspector.testRealFoundationProcessRoutesFailureWithoutNetworkOrCookies() }),
        ]
        for (name, body) in cases {
            let before = Checks.counts
            do { try await body() } catch { recordFailure("\(name) threw: \(error)") }
            let after = Checks.counts
            if after.assertions == before.assertions { recordFailure("\(name) made no assertions") }
            print("\(Checks.counts.failures == before.failures ? "PASS" : "FAIL") \(name)")
        }
        alarm(0)
        let result = Checks.counts
        print("\(cases.count) cases, \(result.assertions) assertions, \(result.failures) failures")
        exit(result.failures == 0 ? 0 : 1)
    }
}
