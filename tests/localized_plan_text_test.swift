import Foundation

@main
struct LocalizedPlanTextTestRunner {
    static func main() {
        testPlanStatusKeysRemainStable()
        print("localized_plan_text_test: ok")
    }

    private static func testPlanStatusKeysRemainStable() {
        assert(LocalizedPlanText.planStatusKey(for: "planned") == "plan.status.planned")
        assert(LocalizedPlanText.planStatusKey(for: "in_progress") == "plan.status.in_progress")
        assert(LocalizedPlanText.planStatusKey(for: "completed") == "plan.status.completed")
        assert(LocalizedPlanText.planStatusKey(for: "skipped") == "plan.status.skipped")
        assert(LocalizedPlanText.planStatusKey(for: "rest") == "plan.status.rest")
        assert(LocalizedPlanText.planStatusKey(for: "unexpected") == "plan.status.unexpected")
    }
}
