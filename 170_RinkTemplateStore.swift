// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

nonisolated struct RinkTemplateStorageService {
    let fileManager: FileManager = .default
    let templatesFileName = "rink_templates.json"

    var templatesDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("RinkTemplates", isDirectory: true)
    }

    func ensureTemplatesDirectory() throws {
        try fileManager.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
    }

    func loadStoreData() throws -> Data? {
        let url = templatesDirectory.appendingPathComponent(templatesFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func persistStoreData(_ data: Data) throws {
        let url = templatesDirectory.appendingPathComponent(templatesFileName)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class RinkTemplateStore: ObservableObject {
    @Published private(set) var templates: [RinkTemplate] = []
    @Published private(set) var activeTemplateID: UUID?
    @Published private(set) var defaultTemplateID: UUID?
    private let storage = RinkTemplateStorageService()

    var activeTemplate: RinkTemplate? {
        guard let activeTemplateID else { return nil }
        return templates.first(where: { $0.id == activeTemplateID })
    }

    enum TemplateError: LocalizedError {
        case emptyName
        case duplicateName
        case notFound

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Template name is required."
            case .duplicateName: return "Template name already exists."
            case .notFound: return "Template not found."
            }
        }
    }

    private struct TemplateStoreFile: Codable {
        var templates: [RinkTemplate]
        var activeTemplateID: UUID?
        var defaultTemplateID: UUID?
    }

    init() { loadTemplates() }

    func saveNewTemplate(template draft: RinkTemplate, imageData: Data?) throws -> RinkTemplate {
        let normalized = normalizeName(draft.name)
        guard !normalized.isEmpty else { throw TemplateError.emptyName }
        guard !hasDuplicateName(normalized, excluding: nil) else { throw TemplateError.duplicateName }

        let imageFileName = try saveImageIfNeeded(data: imageData)
        var template = draft
        template.id = UUID()
        template.createdAt = .now
        template.modifiedAt = .now
        template.zoneRevision = max(1, draft.zoneRevision)
        template.name = normalized
        template.venueName = draft.venueName.normalized
        template.notes = draft.notes.normalized
        template.scoreboardType = draft.scoreboardType.normalized.isEmpty ? "Standard" : draft.scoreboardType.normalized
        template.imageFileName = imageFileName ?? draft.imageFileName

        templates.append(template)
        activeTemplateID = template.id
        try persistTemplates()
        recordTemplateTransition(event: "profile_created", templateID: template.id, next: ["name": template.name, "revision": String(template.zoneRevision)], reason: "New rink profile saved and selected")
        return template
    }

    func updateTemplate(id: UUID, template draft: RinkTemplate, imageData: Data?) throws -> RinkTemplate {
        let normalized = normalizeName(draft.name)
        guard !normalized.isEmpty else { throw TemplateError.emptyName }
        guard let index = templates.firstIndex(where: { $0.id == id }) else { throw TemplateError.notFound }
        guard !hasDuplicateName(normalized, excluding: id) else { throw TemplateError.duplicateName }

        let existing = templates[index]
        var template = draft
        template.id = id
        template.createdAt = existing.createdAt
        template.name = normalized
        template.modifiedAt = .now
        template.zoneRevision = max(existing.zoneRevision + 1, draft.zoneRevision + 1)
        template.venueName = draft.venueName.normalized
        template.notes = draft.notes.normalized
        template.scoreboardType = draft.scoreboardType.normalized.isEmpty ? "Standard" : draft.scoreboardType.normalized
        template.isDefault = existing.isDefault
        template.isFavorite = existing.isFavorite
        template.imageFileName = existing.imageFileName

        if let imageData {
            let oldImage = existing.imageFileName
            template.imageFileName = try saveImageIfNeeded(data: imageData)
            removeImageIfUnused(named: oldImage, excluding: id)
        }

        templates[index] = template
        activeTemplateID = id
        try persistTemplates()
        recordTemplateTransition(event: "profile_updated", templateID: template.id, previous: ["name": existing.name, "revision": String(existing.zoneRevision)], next: ["name": template.name, "revision": String(template.zoneRevision)], reason: "Rink profile updated")
        return template
    }

    func duplicateTemplate(id: UUID, newName: String) throws -> RinkTemplate {
        guard let source = templates.first(where: { $0.id == id }) else { throw TemplateError.notFound }
        let normalized = normalizeName(newName)
        guard !normalized.isEmpty else { throw TemplateError.emptyName }
        guard !hasDuplicateName(normalized, excluding: nil) else { throw TemplateError.duplicateName }

        var duplicate = source
        duplicate.id = UUID()
        duplicate.name = normalized
        duplicate.createdAt = .now
        duplicate.modifiedAt = .now
        duplicate.zoneRevision = 1
        duplicate.isDefault = false

        if let sourceImageFileName = source.imageFileName {
            duplicate.imageFileName = try copyImage(named: sourceImageFileName)
        }

        templates.append(duplicate)
        activeTemplateID = duplicate.id
        try persistTemplates()
        recordTemplateTransition(event: "profile_duplicated", templateID: duplicate.id, next: ["name": duplicate.name, "sourceID": source.id.uuidString], reason: "Rink profile duplicated and selected")
        return duplicate
    }

    func renameTemplate(id: UUID, newName: String) throws {
        let normalized = normalizeName(newName)
        guard !normalized.isEmpty else { throw TemplateError.emptyName }
        guard let index = templates.firstIndex(where: { $0.id == id }) else { throw TemplateError.notFound }
        guard !hasDuplicateName(normalized, excluding: id) else { throw TemplateError.duplicateName }
        let previousName = templates[index].name
        templates[index].name = normalized
        templates[index].modifiedAt = .now
        try persistTemplates()
        recordTemplateTransition(event: "profile_renamed", templateID: id, previous: ["name": previousName], next: ["name": normalized], reason: "Operator renamed rink profile")
    }

    func deleteTemplate(id: UUID) throws {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { throw TemplateError.notFound }
        let removed = templates.remove(at: index)
        removeImageIfUnused(named: removed.imageFileName, excluding: id)
        if activeTemplateID == id { activeTemplateID = nil }
        if defaultTemplateID == id { defaultTemplateID = nil }
        try persistTemplates()
        recordTemplateTransition(event: "profile_deleted", templateID: id, previous: ["name": removed.name], reason: "Operator deleted rink profile")
    }

    func setDefaultTemplate(id: UUID?) throws {
        let previous = defaultTemplateID
        defaultTemplateID = id
        for index in templates.indices {
            templates[index].isDefault = (templates[index].id == id)
        }
        try persistTemplates()
        recordTemplateTransition(event: "default_profile_changed", templateID: id, previous: ["id": previous?.uuidString ?? "none"], next: ["id": id?.uuidString ?? "none"], reason: "Operator changed default rink profile")
    }

    func setActiveTemplate(id: UUID?) throws {
        let previous = activeTemplateID
        activeTemplateID = id
        try persistTemplates()
        recordTemplateTransition(event: "active_profile_changed", templateID: id, previous: ["id": previous?.uuidString ?? "none"], next: ["id": id?.uuidString ?? "none"], reason: "Operator changed active rink profile")
    }

    func imageURL(for template: RinkTemplate) -> URL {
        templatesDirectory.appendingPathComponent(template.imageFileName ?? "")
    }

    func assetURL(for fileName: String) -> URL {
        templatesDirectory.appendingPathComponent(fileName)
    }

    private func loadTemplates() {
        do {
            try storage.ensureTemplatesDirectory()
            guard let data = try storage.loadStoreData() else {
                templates = []
                return
            }
            if let file = try? JSONDecoder().decode(TemplateStoreFile.self, from: data) {
                templates = file.templates
                activeTemplateID = file.activeTemplateID
                defaultTemplateID = file.defaultTemplateID ?? file.templates.first(where: { $0.isDefault })?.id
            } else {
                templates = try JSONDecoder().decode([RinkTemplate].self, from: data)
                activeTemplateID = nil
                defaultTemplateID = templates.first(where: { $0.isDefault })?.id
            }
        } catch {
            templates = []
            activeTemplateID = nil
            defaultTemplateID = nil
        }
    }

    private func recordTemplateTransition(
        event: String,
        templateID: UUID?,
        previous: [String: String] = [:],
        next: [String: String] = [:],
        reason: String
    ) {
        RinkLensStructuredEventLogger.shared.record(
            domain: .rinkProfile,
            event: event,
            entityID: templateID?.uuidString,
            previous: previous,
            next: next,
            source: "RinkTemplateStore",
            reason: reason
        )
    }

    private func persistTemplates() throws {
        let payload = TemplateStoreFile(templates: templates, activeTemplateID: activeTemplateID, defaultTemplateID: defaultTemplateID)
        let data = try JSONEncoder().encode(payload)
        try storage.ensureTemplatesDirectory()
        try storage.persistStoreData(data)
    }

    private func hasDuplicateName(_ name: String, excluding id: UUID?) -> Bool {
        templates.contains {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame && $0.id != id
        }
    }

    private func normalizeName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveImageIfNeeded(data: Data?) throws -> String? {
        guard let data else { return nil }
        try storage.ensureTemplatesDirectory()
        let imageFileName = "rink_\(UUID().uuidString).jpg"
        let imageURL = templatesDirectory.appendingPathComponent(imageFileName)
        try data.write(to: imageURL, options: .atomic)
        return imageFileName
    }

    private func copyImage(named fileName: String) throws -> String? {
        let sourceURL = templatesDirectory.appendingPathComponent(fileName)
        guard storage.fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        let destinationFileName = "rink_\(UUID().uuidString).jpg"
        let destinationURL = templatesDirectory.appendingPathComponent(destinationFileName)
        try storage.fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationFileName
    }

    private func removeImageIfUnused(named fileName: String?, excluding templateID: UUID?) {
        guard let fileName else { return }
        let stillReferenced = templates.contains {
            $0.id != templateID && $0.imageFileName == fileName
        }
        guard !stillReferenced else { return }
        try? storage.fileManager.removeItem(at: templatesDirectory.appendingPathComponent(fileName))
    }

    private var templatesDirectory: URL {
        storage.templatesDirectory
    }
}


#endif
