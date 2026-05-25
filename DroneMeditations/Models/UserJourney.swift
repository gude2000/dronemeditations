import Foundation

/// A user-composed scripted meditation. Same shape as the built-in
/// `Journey` but persisted in UserDefaults so the user can save / edit /
/// delete their own multi-stage sessions. The runtime collapses both
/// sources into one list at the lookup site (`DroneViewModel.journey(forId:)`)
/// so `startJourney(id)` works identically for both.
struct UserJourney: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var description: String
    let createdAt: Date
    var stages: [Stage]

    struct Stage: Codable, Hashable {
        var durationSec: TimeInterval
        var presetName: String       // matches Preset.name
        var driftSceneId: String     // matches DroneViewModel.driftScenes id
        var hint: String
    }

    var totalSeconds: TimeInterval {
        stages.reduce(0) { $0 + $1.durationSec }
    }

    static func newId() -> String {
        "userj-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
    }
}

// MARK: - Storage

enum UserJourneyStore {
    private static let key = "dronemeditations.userJourneys"

    static func load() -> [UserJourney] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([UserJourney].self, from: data)) ?? []
    }

    static func save(_ list: [UserJourney]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
