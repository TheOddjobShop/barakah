import Testing
import Foundation
import AppKit
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
/// Compiling needs the target app's scripting terminology, so a player that is
/// not installed on this machine cannot be checked and is skipped. Installation
/// is tested with `NSWorkspace` rather than inferred from the compile error:
/// `compileAndReturnError` returns false with a *nil* error dictionary for a
/// missing app about as often as it returns -1728, which made an
/// error-code-based skip flaky.
@Suite("AppleScript sources")
struct ScriptCompilationTests {

    private func isInstalled(_ player: ScriptablePlayer) -> Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: player.bundleIdentifier
        ) != nil
    }

    private func check(_ source: String, _ label: String) {
        guard let script = NSAppleScript(source: source) else {
            Issue.record("\(label): NSAppleScript refused the source outright")
            return
        }
        var error: NSDictionary?
        guard !script.compileAndReturnError(&error) else { return }

        let code = error.map(ScriptablePlayerController.errorNumber(from:)) ?? 0
        let message = error?[NSAppleScript.errorMessage] as? String ?? "no error detail"
        Issue.record("\(label) failed to compile (\(code)): \(message)")
    }

    @Test("Every installed player's scripts compile", arguments: ScriptablePlayer.all)
    func playerScriptsCompile(player: ScriptablePlayer) {
        // An app that is not on this machine has no scripting terminology to
        // compile against, so there is nothing to assert. The shape test below
        // is what covers those.
        guard isInstalled(player) else { return }
        check(player.stateScript, "\(player.applicationName) state")
        check(player.pauseScript, "\(player.applicationName) pause")
        check(player.playScript, "\(player.applicationName) play")
    }

    /// Catches the VLC bug on machines without VLC.
    ///
    /// AppleScript's compact `tell application … to <statement>` form takes a
    /// single statement, and its one-line `if` accepts no `else`. Written that
    /// way the script fails to compile with -2740, which
    /// `ScriptablePlayerController` treats as "player unavailable" — so the
    /// player is silently never detected. Since an uninstalled app cannot be
    /// compile-checked at all, the shape is checked directly.
    @Test("No script uses a one-line if with an else", arguments: ScriptablePlayer.all)
    func noOneLineIfElse(player: ScriptablePlayer) {
        for (name, source) in [("state", player.stateScript),
                               ("pause", player.pauseScript),
                               ("play", player.playScript)] {
            let isCompactForm = source.contains(" to if ")
            #expect(!(isCompactForm && source.contains(" else ")),
                    "\(player.applicationName) \(name): a one-line `if` cannot carry an `else`")
        }
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
