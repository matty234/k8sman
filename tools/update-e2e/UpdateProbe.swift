// Headless Sparkle driver for the local update test (tools/update-e2e.sh).
//
//   update-probe <installed k8sman.app> <feed-url>
//
// Runs the same Sparkle framework the app ships (linked from the built app)
// against an installed copy of the app: check the feed, download, verify the
// EdDSA signatures (feed and archive), extract, and install by replacing the
// bundle. It never launches the app (relaunch is declined), so it can run
// without a GUI session being touched. Exit status: 0 installed, 1 error
// (e.g. signature rejected), 2 no update found.
import Foundation
import Sparkle

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) { print("probe: \(s)") }

final class Delegate: NSObject, SPUUpdaterDelegate {
  let feed: String
  init(feed: String) { self.feed = feed }
  func feedURLString(for updater: SPUUpdater) -> String? { feed }
  // Don't start the (GUI) app after installing.
  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
  func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
    log("feed loaded: \(appcast.items.map { $0.displayVersionString })")
  }
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    log("aborted: \(error.localizedDescription) \((error as NSError).userInfo[NSUnderlyingErrorKey] ?? "")")
  }
}

final class Driver: NSObject, SPUUserDriver {
  var status: Int32 = 1
  func finish(_ code: Int32, _ msg: String) {
    status = code
    log(msg)
    CFRunLoopStop(CFRunLoopGetMain())
  }

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { log("checking") }
  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    log("update found: \(appcastItem.displayVersionString) (\(appcastItem.versionString)), stage \(state.stage.rawValue)")
    reply(.install)
  }
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    finish(2, "no update: \(error.localizedDescription)")
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    let ns = error as NSError
    let under = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ""
    acknowledgement()
    finish(1, "error: \(ns.localizedDescription) \(under)")
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) { log("downloading") }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
  func showDownloadDidReceiveData(ofLength length: UInt64) {}
  func showDownloadDidStartExtractingUpdate() { log("verifying and extracting") }
  func showExtractionReceivedProgress(_ progress: Double) {}
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    log("ready to install")
    reply(.install)
  }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    log("installing (app terminated: \(applicationTerminated))")
  }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    finish(0, "installed (relaunched: \(relaunched))")
  }
  func showUpdateInFocus() {}
  func dismissUpdateInstallation() {
    // Ends every session; keep the first verdict.
    if status == 1 { CFRunLoopStop(CFRunLoopGetMain()) }
  }
}

let args = CommandLine.arguments
guard args.count == 3, let bundle = Bundle(path: args[1]) else {
  FileHandle.standardError.write("usage: update-probe <app> <feed-url>\n".data(using: .utf8)!)
  exit(64)
}
let driver = Driver()
let delegate = Delegate(feed: args[2])
let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
do {
  try updater.start()
} catch {
  log("could not start updater: \(error)")
  exit(1)
}
updater.checkForUpdates()
// Bounded wait: a stuck install fails the test instead of hanging it.
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { driver.finish(1, "timed out") }
CFRunLoopRun()
exit(driver.status)
