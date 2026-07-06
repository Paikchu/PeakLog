import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = rootURL.appendingPathComponent("PeakLog/Views/Today/ExerciseCardView.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)

precondition(
    source.contains("ToolbarItemGroup(placement: .keyboard)"),
    "Expected ValueEditSheet to provide a keyboard toolbar done action for number pads"
)
precondition(
    source.contains("focused = false"),
    "Expected ValueEditSheet keyboard toolbar to dismiss the keyboard before commit"
)

print("today_value_edit_sheet_test passed")
