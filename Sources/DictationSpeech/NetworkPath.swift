import Foundation
import Network

/// Whether the Mac has any network route. A route does not prove Soniox is reachable,
/// so only a definite "no route" is reported as offline; unknown counts as online.
@MainActor final class NetworkPath {
    private let monitor = NWPathMonitor()
    private(set) var isOffline = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.isOffline = path.status == .unsatisfied }
        }
        monitor.start(queue: .main)
    }

    isolated deinit { monitor.cancel() }
}
