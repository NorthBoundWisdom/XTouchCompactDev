import ChassisRemoteBinding
import RobotRemoteBinding
import SimulationContracts
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

@Test func realtimeGapFaultsAndFreezesUnknownOrActiveSimulationsWithoutAutomaticRestart() throws {
    for active in [false, true] {
        var host = try CompactPluginHost.agent(at: 100)
        try host.installOptional([.robot, .chassis], lifetimeID: "gap-test", at: 100)
        var robot = try #require(host.binding("robot.reference", as: RobotRemoteBinding.self))
        var chassis = try #require(host.binding("chassis.reference", as: ChassisRemoteBinding.self))
        #expect(robot.plugin.maxCatchUpGap == 2 && chassis.plugin.maxCatchUpGap == 2)
        if active {
            try robot.plugin.simulator.initialize([0, 0, 0, 0, 0, 0], generation: robot.plugin.simulator.control.generation)
            let robotGrant = try robot.plugin.simulator.acquire(generation: robot.plugin.simulator.control.generation, owner: "owner", ttl: 5, controlToken: "robot-opaque-token")
            try robot.plugin.simulator.enable(.init(generation: robotGrant.generation, token: robotGrant.control_token, sequence: 1))
            try robot.plugin.simulator.move(.init(generation: robotGrant.generation, token: robotGrant.control_token, sequence: 2), target: [0.05, 0, 0, 0, 0, 0], duration: 1, validFor: 1)
            let robotEvent = try robot.plugin.simulationEvent(at: 100)
            try host.replaceBinding(robot, at: 100, event: robotEvent)
            try chassis.plugin.simulator.initialize([0, 0, 0], generation: chassis.plugin.simulator.control.generation)
            let chassisGrant = try chassis.plugin.simulator.acquire(generation: chassis.plugin.simulator.control.generation, owner: "owner", ttl: 5, controlToken: "chassis-opaque-token")
            try chassis.plugin.simulator.enable(.init(generation: chassisGrant.generation, token: chassisGrant.control_token, sequence: 1))
            try chassis.plugin.simulator.drive(.init(generation: chassisGrant.generation, token: chassisGrant.control_token, sequence: 2), speed: 0.3, steering: 0.1, validFor: 1)
            let chassisEvent = try chassis.plugin.simulationEvent(at: 100)
            try host.replaceBinding(chassis, at: 100, event: chassisEvent)
        }
        try host.advance(to: 100.25)
        let beforeRobot = try #require(host.binding("robot.reference", as: RobotRemoteBinding.self)).plugin.simulator.snapshot()
        let beforeChassis = try #require(host.binding("chassis.reference", as: ChassisRemoteBinding.self)).plugin.simulator.snapshot()
        try host.advance(to: 10000) // The missed interval must never be synchronously replayed.
        let failedRobot = try #require(host.binding("robot.reference", as: RobotRemoteBinding.self)).plugin.simulator.snapshot()
        let failedChassis = try #require(host.binding("chassis.reference", as: ChassisRemoteBinding.self)).plugin.simulator.snapshot()
        #expect(failedRobot.metadata.simulated_time_s == beforeRobot.metadata.simulated_time_s)
        #expect(failedChassis.metadata.simulated_time_s == beforeChassis.metadata.simulated_time_s)
        #expect(failedRobot.metadata.fault == "host_clock_gap" && failedChassis.metadata.fault == "host_clock_gap")
        #expect(!failedRobot.metadata.enabled && !failedChassis.metadata.enabled)
        #expect(failedRobot.metadata.generation != beforeRobot.metadata.generation)
        #expect(failedChassis.metadata.generation != beforeChassis.metadata.generation)
        #expect(failedRobot.metadata.control_owner == nil && failedChassis.metadata.control_owner == nil)
        #expect(failedRobot.actual?.joints_rad == beforeRobot.actual?.joints_rad)
        #expect(failedChassis.actual?.pose_m_rad == beforeChassis.actual?.pose_m_rad)
        try host.advance(to: 10000.1)
        let recoveredRobot = try #require(host.binding("robot.reference", as: RobotRemoteBinding.self)).plugin.simulator.snapshot()
        let recoveredChassis = try #require(host.binding("chassis.reference", as: ChassisRemoteBinding.self)).plugin.simulator.snapshot()
        #expect(recoveredRobot.metadata.fault == "host_clock_gap" && recoveredChassis.metadata.fault == "host_clock_gap")
        #expect(!recoveredRobot.metadata.enabled && !recoveredChassis.metadata.enabled)
        #expect(!recoveredRobot.motion_active)
        // Unknown actual state must stay unknown, not become a fabricated stopped observation.
        #expect(recoveredRobot.stopped == active)
        #expect(recoveredChassis.stopped == active)
        #expect(recoveredRobot.actual?.joints_rad == beforeRobot.actual?.joints_rad)
        #expect(recoveredChassis.actual?.pose_m_rad == beforeChassis.actual?.pose_m_rad)
    }
}

@Test func hostMotionEventsAreCoalescedButCriticalStopIsImmediate() throws {
    var host = try CompactPluginHost.agent()
    try host.installOptional([.chassis], lifetimeID: "cadence-test", at: 0)
    var chassis = try #require(host.binding("chassis.reference", as: ChassisRemoteBinding.self))
    try chassis.plugin.simulator.initialize([0, 0, 0], generation: chassis.plugin.simulator.control.generation)
    let grant = try chassis.plugin.simulator.acquire(generation: chassis.plugin.simulator.control.generation, owner: "owner", ttl: 5, controlToken: "cadence-opaque-token")
    try chassis.plugin.simulator.enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1))
    try chassis.plugin.simulator.drive(.init(generation: grant.generation, token: grant.control_token, sequence: 2), speed: 0.3, steering: 0, validFor: 2)
    let event = try chassis.plugin.simulationEvent(at: 0)
    try host.replaceBinding(chassis, at: 0, event: event)
    func args(_ epoch: String, _ after: Int) -> JSONValue {
        .object(["epoch": .string(epoch), "after": .string(String(after)), "limit": .number(1024)])
    }
    let initial = try host.callRemote("surface_events", arguments: args("discover", 0), context: .init(time: 0))
    let epoch = try #require(initial.value(for: "epoch")?.stringValue)
    let start = try #require(initial.value(for: "latestSequence")?.intValue)
    for index in 1 ... 100 {
        try host.advance(to: Double(index) / 100)
    }
    let active = try host.callRemote("surface_events", arguments: args(epoch, start), context: .init(time: 1))
    let motionEvents = try #require(active.value(for: "events")?.arrayValue)
    #expect(!motionEvents.isEmpty && motionEvents.count <= 5)
    let beforeStop = try #require(active.value(for: "latestSequence")?.intValue)
    try host.handle(.invoke(.init(pluginID: "chassis", actionID: "chassis.stop"), origin: .interface), instanceID: "chassis.reference", at: 1.001)
    let stopped = try host.callRemote("surface_events", arguments: args(epoch, beforeStop), context: .init(time: 1.001))
    let critical = try #require(stopped.value(for: "events")?.arrayValue)
    #expect(critical.count == 1)
    #expect(critical.first?.value(for: "time")?.finiteNumber == 1.001)
    #expect(host.binding("chassis.reference", as: ChassisRemoteBinding.self)?.plugin.simulator.control.owner == nil)
}
