import AppIntents
import Foundation

/// A SherlockEQ hearing profile, surfaced to Shortcuts / Siri so actions can
/// take a profile picker populated from the user's live profile list.
struct ProfileEntity: AppEntity {
    let id: UUID
    let name: String
    let isBuiltIn: Bool

    init(id: UUID, name: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }

    init(_ profile: HearingProfile) {
        self.init(id: profile.id, name: profile.name, isBuiltIn: profile.isBuiltIn)
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Hearing Profile")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isBuiltIn ? "Built-in preset" : nil
        )
    }

    static var defaultQuery = ProfileEntityQuery()
}

/// Looks profiles up by identifier (for stored Shortcuts) and by name (for the
/// "matching" search field), and lists them all as suggestions for the picker.
struct ProfileEntityQuery: EntityStringQuery {

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        AppControlService.snapshotProfiles()
            .filter { identifiers.contains($0.id) }
            .map(ProfileEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ProfileEntity] {
        let needle = string.lowercased()
        return AppControlService.snapshotProfiles()
            .filter { $0.name.lowercased().contains(needle) }
            .map(ProfileEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ProfileEntity] {
        AppControlService.snapshotProfiles().map(ProfileEntity.init)
    }
}
