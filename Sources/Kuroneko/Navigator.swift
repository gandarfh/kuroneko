import Observation

/// Where the window should go when something outside it asks, such as the
/// menu: a meeting, the Pendências or the Ajustes. The window takes
/// the request when it appears, or right away when it is already open.
@MainActor
@Observable
final class Navigator {
    static let shared = Navigator()

    enum Request: Equatable {
        case meeting(Int64)
        case tasks
        case settings
    }

    private(set) var request: Request?

    func go(to request: Request) {
        self.request = request
    }

    func take() -> Request? {
        defer { request = nil }
        return request
    }
}
