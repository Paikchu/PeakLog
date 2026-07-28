import Foundation

// Regression guard for Issue #102 — "sync must be silent".
//
// Why this exists at all: the write model is local-first. A mutation's `await`
// only covers the local write; the cloud push happens afterwards in the
// background, where the user can neither wait for it nor influence it. So a
// "not synced" indicator would raise anxiety without changing a single
// outcome — the product decision is that NO sync state (`idle` / `syncing` /
// `pendingRetry`) ever reaches the UI. PR #101 removed the last surface
// (`ProfileScreen.syncStatusRow` / `syncStatusIcon` / `syncStatusText`).
//
// Why a *test* rather than a comment: once the display is gone the decision
// leaves no trace in the code, and re-adding it is the intuitive move —
// `CloudSyncController.syncStatus` is an `@Published` property on an
// `ObservableObject` already in the environment, so binding it into a view
// compiles, looks helpful, and passes review unless someone happens to
// remember this issue. This test is what makes the constraint enforceable
// instead of remembered.
//
// It also fails if the retired localization keys are *deleted*. Issue #102
// says keep-but-don't-use: the translations are already written and reviewed,
// and deleting them means a future decision to surface sync state (or an
// unrelated cleanup pass) silently throws that work away. Both directions —
// wiring the state back in, and dropping the strings — are deviations from
// the recorded decision, so both are asserted.
//
// Compile with (no app sources needed — this test only reads files):
//   swiftc tests/silent_sync_contract_test.swift -o /tmp/silent_sync_contract_test \
//     && /tmp/silent_sync_contract_test
// Run from the repo root; every path below resolves against the current
// directory.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func source(_ relativePath: String) -> String {
    guard let text = try? String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8
    ) else {
        fputs("FAIL: cannot read \(relativePath) — run this test from the repo root\n", stderr)
        exit(1)
    }
    return text
}

/// Every `.swift` file under one of the app targets, as a repo-root-relative
/// path so failure messages are copy-pasteable.
func swiftFiles(under relativePath: String) -> [String] {
    let base = root.appendingPathComponent(relativePath)
    guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
        fputs("FAIL: cannot enumerate \(relativePath) — run this test from the repo root\n", stderr)
        exit(1)
    }
    var paths: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        paths.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
    }
    return paths.sorted()
}

// All shipping targets, not just the main app: the constraint is "no user-facing
// surface shows sync state", and the Live Activity is a user-facing surface too.
let appSwiftFiles = ["PeakLog", "PeakLogShared", "PeakLogLiveActivityExtension"]
    .flatMap(swiftFiles(under:))

/// The one place sync state is allowed to exist. Everything outside it is UI or
/// on the path to UI.
let syncStateHome = "PeakLog/Services/Cloud/"

// Self-check: a broken walk (wrong cwd, renamed target directory) must fail
// loudly rather than vacuously "pass" by scanning nothing.
require(
    appSwiftFiles.count > 50,
    "Only found \(appSwiftFiles.count) Swift files under the app targets — the scan is broken, "
        + "not the codebase. Run this test from the repo root."
)
require(
    appSwiftFiles.contains(where: { $0.hasPrefix(syncStateHome) }),
    "No files found under \(syncStateHome). If the cloud sync layer moved, update `syncStateHome` "
        + "here so the exclusion still points at the real sync layer."
)

// MARK: - No sync state outside the sync layer

// Matched as written, not as bare words. `CloudSyncStatus` is unambiguous — it
// is this project's type name and nothing else spells it. `syncStatus` on its
// own is NOT: it is a generic identifier another feature could legitimately
// declare (a HealthKit import status, say), and it also appears in prose
// comments. Matching it bare would fail this test on code that never touches
// cloud sync, which is how a guard earns a reputation for crying wolf and gets
// deleted. So `syncStatus` is only matched as a *member access* — `.syncStatus`
// (reading the controller's property) and `$syncStatus` (binding its
// publisher). Those two spellings are what "the UI reached for sync state"
// actually looks like; an unrelated local named `syncStatus` is not.
let syncStateSymbols = ["CloudSyncStatus", ".syncStatus", "$syncStatus"]

for path in appSwiftFiles where !path.hasPrefix(syncStateHome) {
    let text = source(path)
    for symbol in syncStateSymbols {
        require(
            !text.contains(symbol),
            """
            \(path) references `\(symbol)`.

            This is the product decision recorded in Issue #102: sync must be SILENT. \
            Sync state (`idle` / `syncing` / `pendingRetry`) must never be read outside \
            \(syncStateHome) — it is internal/diagnostic only and must not reach any UI. \
            Pushes are local-first and happen in the background; the user cannot act on a \
            failure, so showing one only creates anxiety. Background retry keeps working \
            regardless (`CloudSyncCoordinator.hasUnpushedChanges` drives `onForeground`, \
            not this status). If the decision has genuinely been reversed, change the issue \
            first, then this test.
            """
        )
    }
}

// MARK: - No view or view model reaches for the retired strings

// Same exclusion as above, for a different reason: `Services/Cloud/` holds no
// SwiftUI at all, but `CloudSyncStatus.swift`'s doc comment names these keys
// while explaining that they are deliberately unused. A plain substring scan
// cannot tell that comment apart from a real lookup, and the documentation is
// worth more than the (unreachable) coverage of a layer that renders nothing.
let retiredSyncKeys = ["profile.sync.idle", "profile.sync.syncing", "profile.sync.pending_retry"]

for path in appSwiftFiles where !path.hasPrefix(syncStateHome) {
    let text = source(path)
    for key in retiredSyncKeys {
        require(
            !text.contains(key),
            """
            \(path) references the localization key "\(key)".

            This is the product decision recorded in Issue #102: sync must be SILENT. \
            The `profile.sync.*` strings are retained in the catalog but deliberately NOT \
            enabled — no view or view model may use them to display sync state.
            """
        )
    }
}

// MARK: - The retired strings stay in the catalog, translations and all

// Parsed as JSON rather than substring-matched, because what Issue #102 asks to
// preserve is the *translated copy*, not the key. A cleanup pass that empties
// `value` or flips `state` to "new" while leaving the key in place would satisfy
// a `contains("\"profile.sync.idle\"")` check and still throw away exactly the
// work the decision says to keep — the en / zh-Hans strings someone already
// wrote and reviewed, so that reversing the decision later is a UI change and
// not a translation round.
let catalogURL = root.appendingPathComponent("PeakLog/Localizable.xcstrings")
guard
    let catalogData = try? Data(contentsOf: catalogURL),
    let catalogJSON = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
    let catalogStrings = catalogJSON["strings"] as? [String: Any]
else {
    fputs("FAIL: cannot parse PeakLog/Localizable.xcstrings as a string catalog\n", stderr)
    exit(1)
}

// Both shipping languages. Hardcoded rather than derived from the catalog: if a
// language were dropped wholesale, deriving would silently shrink the assertion
// to whatever survived.
let requiredLocalizations = ["en", "zh-Hans"]

for key in retiredSyncKeys {
    require(
        catalogStrings[key] != nil,
        """
        The localization key "\(key)" is missing from PeakLog/Localizable.xcstrings.

        Issue #102 says these keys are retained but not enabled — deleting them is a \
        deviation just like displaying them. The en / zh-Hans translations are already \
        written; keep them so a future reversal of the decision does not have to redo \
        the copy work.
        """
    )

    let localizations = (catalogStrings[key] as? [String: Any])?["localizations"] as? [String: Any]
    for language in requiredLocalizations {
        let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        let value = unit?["value"] as? String
        let state = unit?["state"] as? String
        require(
            !(value ?? "").isEmpty && state == "translated",
            """
            The "\(language)" translation of "\(key)" is missing, empty, or no longer \
            marked "translated" (value: \(value.map { "\"\($0)\"" } ?? "none"), \
            state: \(state ?? "none")).

            Issue #102 retains these strings precisely so the copy survives the decision. \
            Emptying or un-translating them is the same loss as deleting the key — it just \
            leaves a hollow entry behind to disguise it.
            """
        )
    }
}

// MARK: - The rationale stays discoverable at the definition

// The failure mode this guards is subtle: the enum's own doc comment used to
// say the state was "surfaced minimally in ProfileScreen", which — after PR
// #101 — actively invited someone to put it back. The pointer to the decision
// has to live where the type is read.
let statusDefinition = source("PeakLog/Services/Cloud/CloudSyncStatus.swift")

require(
    statusDefinition.contains("Issue #102"),
    """
    PeakLog/Services/Cloud/CloudSyncStatus.swift no longer points at Issue #102.

    The silent-sync decision must stay documented at the definition of the state it \
    constrains — that comment is the only thing a reader sees before deciding whether \
    binding this enum into a view is acceptable.
    """
)

print("silent_sync_contract_test passed")
