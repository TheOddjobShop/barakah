import Testing
import Foundation
@testable import Barakah

/// Every AppleScript Barakah ships must actually compile.
///
/// This exists because of a bug that shipped silently: VLC's state script used
/// the compact `tell application … to if … then … else …` form, and AppleScript's
/// one-line `if` accepts no `else` clause. It failed to compile with error
/// -2740, `ScriptablePlayerController.run` treated the failure as "this player
/// is unavailable", and VLC was simply never detected — no crash, no log, no
/// symptom until someone noticed their film kept playing through the athan.
///
/// Compiling needs the target app's scripting terminology, so an app that is not
/// installed on the test machine reports -1728 and is skipped. Any *other*
/// error is a genuine defect in the script text.
@Suite("AppleScript sources")
struct ScriptCompilationTests {

    /// "Can't get application id …" — the app simply is not on this machine.
    private static let appNotInstalled = -1728

    private func check(_ source: String, _ label: String) {
        guard let script = NSAppleScript(source: source) else {
            Issue.record("\(label): NSAppleScript refused the source outright")
            return
        }
        var error: NSDictionary?
        guard !script.compileAndReturnError(&error) else { return }

        let code = error.map(ScriptablePlayerController.errorNumber(from:)) ?? 0
        guard code != Self.appNotInstalled else { return }   // not installed here

        let message = error?[NSAppleScript.errorMessage] as? String ?? "unknown error"
        Issue.record("\(label) failed to compile (\(code)): \(message)")
    }

    @Test("Every player's scripts compile", arguments: ScriptablePlayer.all)
    func playerScriptsCompile(player: ScriptablePlayer) {
        check(player.stateScript, "\(player.applicationName) state")
        check(player.pauseScript, "\(player.applicationName) pause")
        check(player.playScript, "\(player.applicationName) play")
    }

    @Test("Every player is uniquely identified")
    func bundleIdentifiersAreUnique() {
        let ids = ScriptablePlayer.all.map(\.bundleIdentifier)
        #expect(Set(ids).count == ids.count, "two players share a bundle identifier")
        #expect(ids.allSatisfy { $0.contains(".") }, "a bundle identifier looks malformed")
    }

    @Test("State scripts ask a question; transport scripts issue a command")
    func scriptsDoWhatTheirNamesSay() {
        for player in ScriptablePlayer.all {
            #expect(player.stateScript.contains("return"),
                    "\(player.applicationName)'s state script returns nothing to inspect")
            // A transport script that returns a value is a sign the state and
            // action scripts got crossed over.
            #expect(!player.pauseScript.contains("player state"),
                    "\(player.applicationName)'s pause script reads state instead of acting")
        }
    }
}
