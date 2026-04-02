import Foundation

@main
struct TrainingPlanContentBlocksTestRunner {
    static func main() throws {
        try decodesWeeklyPlanBlock()
        try decodesTodayPlanBlock()
        print("training_plan_content_blocks_test passed")
    }

    private static func decodesWeeklyPlanBlock() throws {
        let json = """
        {
          "id": "message-weekly-plan",
          "conversation_id": "conversation-1",
          "role": "assistant",
          "content": "我已经生成了本周计划。",
          "created_at": "2026-03-24T00:00:00Z",
          "status": "completed",
          "parse_status": "completed",
          "content_blocks": [
            {
              "type": "weekly_plan",
              "plan_id": "plan-1",
              "week_start_date": "2026-03-23",
              "goal_summary": "增肌，重点提升卧推",
              "coach_summary": "本周 4 练，推拉腿 + 恢复",
              "days": [
                {
                  "plan_day_id": "day-1",
                  "plan_date": "2026-03-24",
                  "day_index": 1,
                  "title": "Push Strength",
                  "focus": "胸肩三头",
                  "status": "planned",
                  "exercises": [
                    {
                      "plan_exercise_id": "exercise-1",
                      "order_index": 0,
                      "exercise_name": "Bench Press",
                      "exercise_load_type": "weighted",
                      "progression_mode": "weight_first",
                      "notes": "全部完成后下周加重",
                      "sets": [
                        {
                          "plan_set_id": "set-1",
                          "set_index": 1,
                          "target_weight": 40,
                          "target_weight_unit": "kg",
                          "target_reps": 8
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))

        guard let block = message.contentBlocks?.first else {
            fatalError("Expected weekly_plan block")
        }

        guard case let .weeklyPlan(plan) = block else {
            fatalError("Expected weeklyPlan block")
        }

        precondition(plan.days.count == 1, "Expected one plan day")
        precondition(plan.days[0].exercises[0].sets[0].targetWeight == 40, "Expected target weight to decode")
    }

    private static func decodesTodayPlanBlock() throws {
        let json = """
        {
          "id": "message-today-plan",
          "conversation_id": "conversation-1",
          "role": "assistant",
          "content": "这是你今天的训练安排。",
          "created_at": "2026-03-24T00:00:00Z",
          "status": "completed",
          "parse_status": "completed",
          "content_blocks": [
            {
              "type": "today_plan",
              "plan_id": "plan-1",
              "goal_summary": "增肌，重点提升卧推",
              "day": {
                "plan_day_id": "day-1",
                "plan_date": "2026-03-24",
                "day_index": 1,
                "title": "Push Strength",
                "focus": "胸肩三头",
                "status": "planned",
                "exercises": [
                    {
                      "plan_exercise_id": "exercise-1",
                      "order_index": 0,
                      "exercise_name": "Bench Press",
                      "exercise_load_type": "weighted",
                      "progression_mode": "weight_first",
                      "notes": null,
                    "sets": [
                      {
                        "plan_set_id": "set-1",
                        "set_index": 1,
                        "target_weight": 40,
                        "target_weight_unit": "kg",
                        "target_reps": 8,
                        "completed_at": null,
                        "linked_exercise_set_id": null
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))

        guard let block = message.contentBlocks?.first else {
            fatalError("Expected today_plan block")
        }

        guard case let .todayPlan(todayPlan) = block else {
            fatalError("Expected todayPlan block")
        }

        precondition(todayPlan.day.title == "Push Strength", "Expected plan day title to decode")
        precondition(todayPlan.day.exercises[0].sets[0].planSetId == "set-1", "Expected plan set ID to decode")
    }
}
