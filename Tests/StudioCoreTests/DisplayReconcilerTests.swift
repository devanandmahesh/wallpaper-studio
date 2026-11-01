import Testing
@testable import StudioCore

@Suite struct DisplayReconcilerTests {
    @Test func firstLaunchAddsEveryDisplay() {
        let plan = DisplayReconciler.plan(existing: [], desired: [3, 1])
        #expect(plan == DisplayPlan(added: [3, 1], removed: [], kept: []))
    }

    @Test func unchangedDisplaysAreKept() {
        let plan = DisplayReconciler.plan(existing: [1, 2], desired: [1, 2])
        #expect(plan == DisplayPlan(added: [], removed: [], kept: [1, 2]))
    }

    @Test func hotPlugAddsOnlyTheNewDisplay() {
        let plan = DisplayReconciler.plan(existing: [1], desired: [1, 7])
        #expect(plan == DisplayPlan(added: [7], removed: [], kept: [1]))
    }

    @Test func unplugRemovesOnlyTheMissingDisplay() {
        let plan = DisplayReconciler.plan(existing: [1, 7, 4], desired: [1])
        #expect(plan == DisplayPlan(added: [], removed: [4, 7], kept: [1]))
    }

    @Test func swappingDisplaysAddsAndRemoves() {
        let plan = DisplayReconciler.plan(existing: [1, 2], desired: [2, 9])
        #expect(plan == DisplayPlan(added: [9], removed: [1], kept: [2]))
    }

    @Test func duplicateIdsAreCollapsed() {
        let plan = DisplayReconciler.plan(existing: [], desired: [5, 5, 6])
        #expect(plan.added == [5, 6])
    }

    @Test func allDisplaysGoneRemovesEverything() {
        let plan = DisplayReconciler.plan(existing: [1, 2], desired: [])
        #expect(plan == DisplayPlan(added: [], removed: [1, 2], kept: []))
    }
}
