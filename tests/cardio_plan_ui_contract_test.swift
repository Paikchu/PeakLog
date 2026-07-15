import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

let screen = try source("PeakLog/Views/Today/TodayWorkoutScreen.swift")
let card = try source("PeakLog/Views/Today/PlannedCardioCard.swift")
let sheet = try source("PeakLog/Views/Today/CardioCompletionSheet.swift")
let dailyRecord = try source("PeakLog/Views/Today/DailyRecordSheet.swift")
let addPlan = try source("PeakLog/Views/Today/AddPlanExerciseSheet.swift")

precondition(screen.contains("CardioCompletionSheet"))
precondition(screen.contains("PlannedCardioCard"))
precondition(screen.contains("exercise.itemType == .cardio"))
precondition(card.contains("targetDurationMinutes"))
precondition(card.contains("targetDistanceKm"))
precondition(card.contains("targetRPE"))
precondition(card.contains("isCardioCompleted"))
precondition(sheet.contains("activityType.supportsDistance"))
precondition(sheet.contains("CardioMetrics("))
precondition(!card.contains("onAddSet"))
precondition(!sheet.contains("targetReps"))
precondition(dailyRecord.contains("CardioActivityType.allCases"))
precondition(dailyRecord.contains("selectedCardioActivity.supportsDistance"))
precondition(dailyRecord.contains("rpeText"))
precondition(dailyRecord.contains("case cardio(CardioMetrics)"))
precondition(addPlan.contains("case cardioForm"))
precondition(addPlan.contains("CardioActivityType.allCases"))
precondition(addPlan.contains("PlanExerciseDraft.cardio("))
precondition(addPlan.contains("selectedCardioActivity.supportsDistance"))

print("cardio plan UI contract passed")
