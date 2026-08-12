import XCTest
@testable import PeakLog

/// 批量调节计划组目标：先锁死纯函数的每条规则（只改一维、相对调节、下界、
/// 自重组），再锁死本地库的写入语义（跳过已完成组、一次写盘、每个真正变化的
/// 组记一条 set_target_updated、no-op 不留痕）。
final class PlannedSetBatchAdjustmentTests: XCTestCase {

    // MARK: - 纯函数

    func testUniformWeightLeavesRepsAlone() {
        let adjustment = PlannedSetBatchAdjustment(weight: .uniform(60, unit: .kg))

        let result = adjustment.applied(to: makeSet(weight: 40, unit: .lbs, reps: 8))

        XCTAssertEqual(result.targetWeight, 60)
        XCTAssertEqual(result.targetWeightUnit, .kg)
        XCTAssertEqual(result.targetReps, 8)
    }

    func testUniformRepsLeavesWeightAlone() {
        let adjustment = PlannedSetBatchAdjustment(reps: .uniform(12))

        let result = adjustment.applied(to: makeSet(weight: 40, unit: .kg, reps: 8))

        XCTAssertEqual(result.targetWeight, 40)
        XCTAssertEqual(result.targetWeightUnit, .kg)
        XCTAssertEqual(result.targetReps, 12)
    }

    func testUniformWeightCanClearToBodyweight() {
        let adjustment = PlannedSetBatchAdjustment(weight: .uniform(nil, unit: .kg))

        let result = adjustment.applied(to: makeSet(weight: 40, unit: .kg, reps: 8))

        XCTAssertNil(result.targetWeight)
    }

    /// 相对调节存在的理由：45/52/55 这种递增结构，统一成一个值就没了。
    func testWeightDeltaPreservesTheRamp() {
        let adjustment = PlannedSetBatchAdjustment(weight: .delta(2.5))
        let ramp = [45.0, 52.0, 55.0].map { makeSet(weight: $0, unit: .kg, reps: 8) }

        let result: [Double?] = ramp.map { adjustment.applied(to: $0).targetWeight }

        XCTAssertEqual(result, [47.5, 54.5, 57.5])
    }

    func testWeightDeltaSkipsBodyweightSets() {
        let adjustment = PlannedSetBatchAdjustment(weight: .delta(5))

        let result = adjustment.applied(to: makeSet(weight: nil, unit: .kg, reps: 10))

        XCTAssertNil(result.targetWeight, "自重组没有可加减的基数，加权只会凭空造出一个重量")
    }

    func testDeltaKeepsWeightAtZeroAndRepsAtOne() {
        let adjustment = PlannedSetBatchAdjustment(weight: .delta(-100), reps: .delta(-100))

        let result = adjustment.applied(to: makeSet(weight: 40, unit: .kg, reps: 8))

        XCTAssertEqual(result.targetWeight, 0)
        XCTAssertEqual(result.targetReps, 1)
    }

    func testUniformValuesAreClampedToo() {
        let adjustment = PlannedSetBatchAdjustment(weight: .uniform(-5, unit: .kg), reps: .uniform(0))

        let result = adjustment.applied(to: makeSet(weight: 40, unit: .kg, reps: 8))

        XCTAssertEqual(result.targetWeight, 0)
        XCTAssertEqual(result.targetReps, 1)
    }

    func testEmptyAdjustmentChangesNothing() {
        let adjustment = PlannedSetBatchAdjustment()
        let set = makeSet(weight: 40, unit: .kg, reps: 8)

        XCTAssertTrue(adjustment.isEmpty)
        XCTAssertEqual(adjustment.applied(to: set), set)
    }

    // MARK: - 本地库写入

    /// 顺带锁死批量的核心性质：三组只写一次盘（`onChange` 只响一次），
    /// 而不是逐组调 `updatePlannedSet` 的三次写盘、三次云推送。
    func testBatchUpdateAppliesToEveryUncompletedSetInOneWrite() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        let writes = WriteCounter()
        await database.armCloudSync(userId: "user-a") { writes.increment() }
        let exercise = try await seedExercise(in: database, weights: [40, 40, 40], reps: 6)
        let baseline = writes.value

        let updated = try await database.batchUpdatePlannedSets(
            planExerciseId: exercise.id,
            adjustment: PlannedSetBatchAdjustment(weight: .uniform(45, unit: .kg), reps: .uniform(8))
        )

        let updatedWeights: [Double?] = updated.sets.map(\.targetWeight)
        XCTAssertEqual(updatedWeights, [45, 45, 45])
        XCTAssertEqual(updated.sets.map(\.targetReps), [8, 8, 8])
        XCTAssertEqual(writes.value - baseline, 1, "批量调节必须只落一次盘")

        let plan = await database.activePlan()
        let persisted = try XCTUnwrap(
            plan?.days.flatMap(\.exercises).first(where: { $0.id == exercise.id })
        )
        let persistedWeights: [Double?] = persisted.sets.map(\.targetWeight)
        XCTAssertEqual(persistedWeights, [45, 45, 45])
    }

    /// 已完成组关联着落库的训练记录，改它的目标会让计划和「实际练了什么」对不上。
    func testBatchUpdateLeavesCompletedSetsUntouched() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        let exercise = try await seedExercise(in: database, weights: [40, 40, 40], reps: 6)
        let completedSetId = exercise.sets[0].id
        _ = try await database.completePlannedSet(
            planSetId: completedSetId,
            actualWeight: 40,
            actualWeightUnit: .kg,
            actualReps: 6
        )

        let updated = try await database.batchUpdatePlannedSets(
            planExerciseId: exercise.id,
            adjustment: PlannedSetBatchAdjustment(weight: .delta(5), reps: .uniform(10))
        )

        let completed = try XCTUnwrap(updated.sets.first(where: { $0.id == completedSetId }))
        XCTAssertEqual(completed.targetWeight, 40)
        XCTAssertEqual(completed.targetReps, 6)

        let rest = updated.sets.filter { $0.id != completedSetId }
        let restWeights: [Double?] = rest.map(\.targetWeight)
        XCTAssertEqual(restWeights, [45, 45])
        XCTAssertEqual(rest.map(\.targetReps), [10, 10])
    }

    func testBatchUpdateRecordsOneEventPerChangedSet() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        await database.armCloudSync(userId: "user-a") {}
        let exercise = try await seedExercise(in: database, weights: [40, 40], reps: 6)
        let baseline = await database.snapshot().pendingEditEvents.count

        _ = try await database.batchUpdatePlannedSets(
            planExerciseId: exercise.id,
            adjustment: PlannedSetBatchAdjustment(weight: .uniform(50, unit: .kg))
        )

        let allEvents = await database.snapshot().pendingEditEvents
        let events = Array(allEvents.dropFirst(baseline))
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.eventType == .setTargetUpdated })

        let payload = try XCTUnwrap(events.first?.payload)
        guard case .object(let fields) = payload,
              case .object(let before)? = fields["before"],
              case .object(let after)? = fields["after"],
              case .number(let beforeWeight)? = before["targetWeight"],
              case .number(let afterWeight)? = after["targetWeight"]
        else {
            return XCTFail("set_target_updated 载荷缺少 before/after 重量")
        }
        XCTAssertEqual(beforeWeight, 40)
        XCTAssertEqual(afterWeight, 50)
    }

    func testEmptyAdjustmentIsANoOp() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        let writes = WriteCounter()
        await database.armCloudSync(userId: "user-a") { writes.increment() }
        let exercise = try await seedExercise(in: database, weights: [40, 40], reps: 6)
        let beforeEvents = await database.snapshot().pendingEditEvents.count
        let baseline = writes.value

        let updated = try await database.batchUpdatePlannedSets(
            planExerciseId: exercise.id,
            adjustment: PlannedSetBatchAdjustment()
        )

        let updatedWeights: [Double?] = updated.sets.map(\.targetWeight)
        XCTAssertEqual(updatedWeights, [40, 40])
        let afterEvents = await database.snapshot().pendingEditEvents.count
        XCTAssertEqual(afterEvents, beforeEvents)
        XCTAssertEqual(writes.value, baseline, "空调节不该产生一次写盘/一次云推送")
    }

    /// 值没真正变化时同样不落库：否则每次打开批量入口点一下「完成」都会制造一条
    /// 噪声编辑事件，污染学习回路读的那条信号。
    func testAdjustmentThatChangesNothingIsANoOp() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)
        let writes = WriteCounter()
        await database.armCloudSync(userId: "user-a") { writes.increment() }
        let exercise = try await seedExercise(in: database, weights: [40, 40], reps: 6)
        let beforeEvents = await database.snapshot().pendingEditEvents.count
        let baseline = writes.value

        _ = try await database.batchUpdatePlannedSets(
            planExerciseId: exercise.id,
            adjustment: PlannedSetBatchAdjustment(weight: .uniform(40, unit: .kg), reps: .uniform(6))
        )

        let afterEvents = await database.snapshot().pendingEditEvents.count
        XCTAssertEqual(afterEvents, beforeEvents)
        XCTAssertEqual(writes.value, baseline)
    }

    func testUnknownExerciseThrows() async throws {
        let fileURL = temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let database = LocalAppDatabase(fileURL: fileURL)

        do {
            _ = try await database.batchUpdatePlannedSets(
                planExerciseId: "does-not-exist",
                adjustment: PlannedSetBatchAdjustment(reps: .uniform(10))
            )
            XCTFail("未知动作 id 必须抛错，而不是静默成功")
        } catch {
            XCTAssertEqual(error as? LocalAppDatabaseError, LocalAppDatabaseError.planExerciseNotFound)
        }
    }

    // MARK: - Helpers

    private func makeSet(weight: Double?, unit: WeightUnit, reps: Int) -> TrainingPlanSet {
        TrainingPlanSet(
            id: UUID().uuidString,
            setIndex: 1,
            targetWeight: weight,
            targetWeightUnit: unit,
            targetReps: reps,
            completedAt: nil,
            linkedExerciseSetId: nil
        )
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peaklog-batch-adjust-\(UUID().uuidString).json")
    }

    private func seedExercise(
        in database: LocalAppDatabase,
        weights: [Double],
        reps: Int
    ) async throws -> TrainingPlanExercise {
        let name = "Batch Row \(UUID().uuidString)"
        let setDrafts: [PlanExerciseDraft.SetDraft] = weights.map { weight in
            PlanExerciseDraft.SetDraft(targetWeight: weight, targetWeightUnit: .kg, targetReps: reps)
        }
        let day = try await database.addPlannedExercises([
            PlanExerciseDraft(
                exerciseName: name,
                exerciseId: "barbell-row",
                isBodyweight: false,
                sets: setDrafts
            )
        ])
        return try XCTUnwrap(day.exercises.first(where: { $0.exerciseName == name }))
    }
}

/// `armCloudSync` 的 onChange 每次成功 `persist()` 响一次，用它数写盘次数。
/// 锁 + `@unchecked Sendable` 沿用仓库既有写法（见 `LocalAppDatabaseWriteRollbackTests`）：
/// 回调是 `@Sendable` 的，从 actor 上调回来。
private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
