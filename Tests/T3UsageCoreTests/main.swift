import Foundation
// Standalone checks intentionally use only Foundation: Apple's Command Line Tools ship
// Swift/AppKit but no XCTest module. These assertions exercise production core code.
var failures = 0
func fail(_ file: StaticString, _ line: UInt) { failures += 1; print("FAIL \(file):\(line)") }
func expectTrue(_ v: Bool, file: StaticString = #filePath, line: UInt = #line) { if !v { fail(file,line) } }
func expectFalse(_ v: Bool, file: StaticString = #filePath, line: UInt = #line) { expectTrue(!v,file:file,line:line) }
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { expectTrue(a == b,file:file,line:line) }
func expectNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { expectTrue(a != b,file:file,line:line) }
func expectNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(a == nil,file:file,line:line) }
func expectNotNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(a != nil,file:file,line:line) }
enum CheckError: Error { case missing }
func unwrap<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { guard let a else { fail(file,line); throw CheckError.missing }; return a }
func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); fail(file,line) } catch {}
}
let tests = CoreTests()
let checks: [(String, () throws -> Void)] = [
    ("decoding and remaining", tests.testDecodingAndConservativeRemaining),
    ("missing and empty", tests.testMissingAndEmptyNeverBecomeFull),
    ("malformed data", tests.testMalformedValuesAndWindowDataFailClosed),
    ("unavailable and probe failure", tests.testUnavailableSnapshotsKeepFailureWithBars),
    ("stale and disconnected", tests.testStaleDisconnectedAndFutureClock),
    ("reset boundaries", tests.testResetBoundaryAndMissingReset),
    ("individual accounts and hubs", tests.testStableIndividualIdentitiesAndHubAccounts),
    ("selection round trip and missing choices", tests.testSelectionPersistenceMissingAccountAndWindow),
    ("hub failure and duplicates", tests.testHubFailureAndDuplicateWindows),
    ("refresh cooldown and overlap", tests.testRefreshGateNoOverlapAndFailureCooldown),
    ("local endpoint validation", tests.testRuntimeRejectsRemoteMalformedAndCredentialURLs),
    ("disabled providers and preserved selection", tests.testDisabledProvidersHiddenAndSelectionPreserved),
    ("manual refresh and overlap", tests.testManualRefreshBypassesTimerButNeverOverlaps),
    ("dates and label sanitation", tests.testDatesAndLabels)
]
for (name, run) in checks {
    let before = failures
    do { try run() } catch { fail(#filePath,#line) }
    print("\(failures == before ? "PASS" : "FAIL") \(name)")
}
print("\(checks.count) check groups, \(failures) failures")
exit(failures == 0 ? 0 : 1)
