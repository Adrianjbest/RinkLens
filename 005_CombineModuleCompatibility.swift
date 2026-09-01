// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
//
// 005_CombineModuleCompatibility.swift
// RinkLens
//
// Swift 6 / Xcode explicit-module compatibility.
//
// ObservableObject, @Published and ObservableObjectPublisher are defined by
// Combine. Swift Playgrounds may make those names visible indirectly through
// SwiftUI, while an Xcode target can require the defining module explicitly.
// Re-export Combine once for this target so the existing model files do not
// each need a separate import, keeping the patch narrow and compile-friendly.
//

#if canImport(Combine)
@_exported import Combine
#endif
