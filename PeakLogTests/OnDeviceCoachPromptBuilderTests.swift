import XCTest
@testable import PeakLog

final class OnDeviceCoachPromptBuilderTests: XCTestCase {
    func testEffectiveLanguagePrefersCurrentAppLanguage() {
        let language = OnDeviceCoachPromptBuilder.effectiveLanguage(
            profileLanguage: .english,
            currentLanguageProvider: { .simplifiedChinese }
        )

        XCTAssertEqual(language, .simplifiedChinese)
    }

    func testInstructionsForceSimplifiedChineseResponse() {
        let context = OnDevicePromptContext(
            weightUnit: .kg,
            timezoneIdentifier: "Asia/Shanghai",
            language: .simplifiedChinese,
            fitnessGoalSummary: nil,
            todayPlanSummary: nil,
            weeklyPlanSummary: nil,
            recentWorkoutsSummary: [],
            userInput: "完成一组硬拉 60kg，10个"
        )

        let instructions = OnDeviceCoachPromptBuilder.instructions(for: context)

        XCTAssertTrue(instructions.contains("The person's locale is zh-Hans."))
        XCTAssertTrue(instructions.contains("You MUST respond in Simplified Chinese."))
    }

    func testInstructionsContainChineseStrengthLoggingExample() {
        let context = OnDevicePromptContext(
            weightUnit: .kg,
            timezoneIdentifier: "Asia/Shanghai",
            language: .simplifiedChinese,
            fitnessGoalSummary: nil,
            todayPlanSummary: nil,
            weeklyPlanSummary: nil,
            recentWorkoutsSummary: [],
            userInput: "完成一组硬拉 60kg，10个"
        )

        let instructions = OnDeviceCoachPromptBuilder.instructions(for: context)

        XCTAssertTrue(instructions.contains("完成一组硬拉 60kg，10个"))
        XCTAssertTrue(instructions.contains("keep the exercise name as \"硬拉\""))
        XCTAssertTrue(instructions.contains("set weight to 60"))
        XCTAssertTrue(instructions.contains("reps to 10"))
        XCTAssertTrue(instructions.contains("Do not replace one exercise with another"))
    }
}
