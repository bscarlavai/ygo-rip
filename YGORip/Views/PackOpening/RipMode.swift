import Foundation

/// How the pack opens.
///
/// - `dynamic` tears along the line you drag (PackTear). Where you drag
///   matters, which is the point, and also the complaint, since a careless
///   swipe can take a corner off instead of opening the pack.
/// - `classic` splits the pack in two wherever you swipe. Direction and
///   distance are all that count, so it cannot be done "wrong".
///
/// YGORip shipped Classic only until 1.0.8. New installs default to Dynamic;
/// anyone who had already opened a pack stays on Classic (see
/// `AppState.resolveRipMode`). Ported from poke-rip, which made the opposite
/// move (Dynamic everywhere since its 1.1.0, Classic added back as an option).
enum RipMode: String, CaseIterable, Sendable {
    case classic
    case dynamic

    var label: String {
        switch self {
        case .classic: "Classic"
        case .dynamic: "Dynamic"
        }
    }

    var settingsFooter: String {
        switch self {
        case .classic:
            "Swipe anywhere across the pack and it splits in two. Where you swipe doesn't matter."
        case .dynamic:
            "The pack tears along the line you drag, so every rip is different. Drag right across it to open."
        }
    }
}
