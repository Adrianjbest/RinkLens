// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import os

/// Recovery U route-performance probe.
///
/// AppCoordinator remains the sole route owner. This object records one set of
/// timing checkpoints for the current route transition so a physical Instruments
/// trace and All Logs export can identify where a visible transition actually
/// spends time without introducing a second navigation state machine.
nonisolated final class RinkLensRoutePerformanceProbe: @unchecked Sendable {
    enum Stage: String, Hashable {
        case routeRequested = "route-requested"
        case routePublished = "route-published"
        case navigateReturned = "navigate-returned"
        case routeTaskStarted = "route-task-started"
        case broadcastViewInitialised = "broadcast-view-init"
        case broadcastShellAppeared = "broadcast-shell-appeared"
        case broadcastViewAppeared = "broadcast-view-appeared"
        case previewMakeUIViewStarted = "preview-make-ui-view-start"
        case previewMakeUIViewCompleted = "preview-make-ui-view-complete"
        case overlayAppeared = "overlay-appeared"
        case previewAttached = "preview-attached"
        case runtimeBridgeStarted = "runtime-bridge-started"
        case operatorChromeReady = "operator-chrome-ready"
    }

    static let shared = RinkLensRoutePerformanceProbe()

    private let lock = NSLock()
    private let signposter = OSSignposter(
        subsystem: "com.rinklens.performance",
        category: "PointsOfInterest"
    )
    private var activeRoute: AppRoute?
    private var transitionStartedNanoseconds: UInt64 = 0
    private var seenStages: Set<Stage> = []

    private init() {}

    func begin(route: AppRoute, source: String) {
        lock.lock()
        activeRoute = route
        transitionStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
        seenStages.removeAll(keepingCapacity: true)
        seenStages.insert(.routeRequested)
        lock.unlock()

        emitSignpost(.routeRequested)
        record(stage: .routeRequested, route: route, source: source, elapsedMilliseconds: 0)
    }

    func mark(_ stage: Stage, route expectedRoute: AppRoute? = nil, source: String) {
        lock.lock()
        guard let route = activeRoute else {
            lock.unlock()
            return
        }
        if let expectedRoute, expectedRoute != route {
            lock.unlock()
            return
        }
        guard seenStages.insert(stage).inserted else {
            lock.unlock()
            return
        }
        let started = transitionStartedNanoseconds
        lock.unlock()

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = started == 0 ? 0 : Double(now &- started) / 1_000_000.0
        emitSignpost(stage)
        record(stage: stage, route: route, source: source, elapsedMilliseconds: elapsed)
    }

    private func record(stage: Stage, route: AppRoute, source: String, elapsedMilliseconds: Double) {
        let elapsedText = String(format: "%.1f", elapsedMilliseconds)
        RinkLensStructuredEventLogger.shared.record(
            domain: .navigation,
            event: "route_performance_stage",
            entityID: route.rawValue,
            previous: ["transitionStart": "route-requested"],
            next: [
                "stage": stage.rawValue,
                "elapsedMs": elapsedText,
                "mainThread": Thread.isMainThread ? "true" : "false"
            ],
            source: source,
            reason: "Recovery U correlates route publication, SwiftUI mount and first preview attachment without changing route/capture ownership",
            authoritativeOwner: "AppCoordinator"
        )
        MainThreadStallMonitor.traceFromAnyQueue(
            RinkLensBuildInfo.traceContext("Recovery U route stage route=\(route.title) stage=\(stage.rawValue) elapsed=\(elapsedText)ms")
        )
    }

    private func emitSignpost(_ stage: Stage) {
        switch stage {
        case .routeRequested:
            signposter.emitEvent("RinkLens Route Requested")
        case .routePublished:
            signposter.emitEvent("RinkLens Route Published")
        case .navigateReturned:
            signposter.emitEvent("RinkLens Navigate Returned")
        case .routeTaskStarted:
            signposter.emitEvent("RinkLens Route Task Started")
        case .broadcastViewInitialised:
            signposter.emitEvent("RinkLens Broadcast View Init")
        case .broadcastShellAppeared:
            signposter.emitEvent("RinkLens Broadcast Shell Appeared")
        case .broadcastViewAppeared:
            signposter.emitEvent("RinkLens Broadcast View Appeared")
        case .previewMakeUIViewStarted:
            signposter.emitEvent("RinkLens Preview MakeUIView Start")
        case .previewMakeUIViewCompleted:
            signposter.emitEvent("RinkLens Preview MakeUIView Complete")
        case .overlayAppeared:
            signposter.emitEvent("RinkLens Overlay Appeared")
        case .previewAttached:
            signposter.emitEvent("RinkLens Preview Attached")
        case .runtimeBridgeStarted:
            signposter.emitEvent("RinkLens Runtime Bridge Started")
        case .operatorChromeReady:
            signposter.emitEvent("RinkLens Operator Chrome Ready")
        }
    }
}

// MARK: - RinkLens NextGen Central App Routing

enum AppRoute: String, CaseIterable, Identifiable, Equatable {
    case commandCentre
    case broadcast
    case ocrSetup
    case recording
    case sponsors
    case media
    case streamSetup
    case diagnostics
    case cameraSetup
    case settings

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .commandCentre: return "Command Centre"
        case .broadcast: return "Broadcast"
        case .ocrSetup: return "Scoreboard Setup"
        case .recording: return "Production Setup"
        case .sponsors: return "Sponsors"
        case .media: return "Media"
        case .streamSetup: return "Production Setup"
        case .diagnostics: return "Diagnostics"
        case .cameraSetup: return "Camera Setup"
        case .settings: return "Settings"
        }
    }
}

/// UX16d1 observer boundary for non-navigation consumers such as controlled
/// validation harnesses. The coordinator owns route state only; observers may
/// record a route transition but must not redirect or mutate engine lifecycle.
@MainActor
protocol AppRouteObserving: AnyObject {
    func appCoordinatorDidNavigate(to route: AppRoute)
}

@MainActor
final class LiveAppRouteObserver: AppRouteObserving {
    func appCoordinatorDidNavigate(to route: AppRoute) {
        RinkLensPhysicalValidationController.shared.noteRouteChange(route)
        RinkLensControlledPilotController.shared.noteRouteChange(route)
        RinkLensGameDayPilotController.shared.noteRouteChange(route)
    }
}

@MainActor
final class NoOpAppRouteObserver: AppRouteObserving {
    func appCoordinatorDidNavigate(to route: AppRoute) {}
}

/// Central navigation coordinator. It is the sole writable owner of the
/// visible NextGen route. Route changes are presentation state only and cannot
/// issue camera, recording, OCR or Image Relay lifecycle commands.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var route: AppRoute

    private let routeObserver: any AppRouteObserving
    init(
        route: AppRoute = .commandCentre,
        routeObserver: (any AppRouteObserving)? = nil
    ) {
        self.route = route
        // Default argument expressions are evaluated outside the callee's
        // actor context. Resolve live collaborators inside this @MainActor
        // initializer so Swift 6/Xcode never constructs them nonisolated.
        self.routeObserver = routeObserver ?? LiveAppRouteObserver()
    }

    func navigate(to route: AppRoute) {
        guard self.route != route else { return }
        let previous = self.route
        RinkLensExecutionCoordinator.shared.beginOperatorInteraction(
            route: route.rawValue,
            source: "AppCoordinator.navigate"
        )
        ClipEngine.shared.requestOperatorPriority(
            reason: "Recovery AF operator route transition \(previous.rawValue) -> \(route.rawValue)"
        )
        RinkLensRoutePerformanceProbe.shared.begin(route: route, source: "AppCoordinator.navigate")
        self.route = route
        RinkLensRoutePerformanceProbe.shared.mark(.routePublished, route: route, source: "AppCoordinator.navigate")
        RinkLensStructuredEventLogger.shared.record(
            domain: .navigation,
            event: "route_changed",
            entityID: "primary",
            previous: ["route": previous.rawValue],
            next: ["route": route.rawValue],
            source: "AppCoordinator.navigate",
            reason: "Operator navigation"
        )
        routeObserver.appCoordinatorDidNavigate(to: route)
        RinkLensRoutePerformanceProbe.shared.mark(.navigateReturned, route: route, source: "AppCoordinator.navigate")
    }
}

#endif
