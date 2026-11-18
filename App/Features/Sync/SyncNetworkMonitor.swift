import Foundation
import Network

/// The network path as sync sees it, behind a protocol so the PDF policy and the scheduler are
/// tested with a fake.
@MainActor
protocol SyncNetworkMonitoring: AnyObject {
    /// The current path; `nil` until the first update.
    var path: SyncNetworkPath? { get }
    /// Called on the main actor whenever the path changes.
    var onChange: ((SyncNetworkPath) -> Void)? { get set }
}

/// `NWPathMonitor`: whether the network is up, expensive (cellular, a hotspot) or constrained
/// (Low Data Mode). All available at iOS 13, below the 17.0 floor.
@MainActor
final class SystemSyncNetworkMonitor: SyncNetworkMonitoring {
    private(set) var path: SyncNetworkPath?
    var onChange: ((SyncNetworkPath) -> Void)?
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] nwPath in
            let path = SyncNetworkPath(isSatisfied: nwPath.status == .satisfied, isExpensive: nwPath.isExpensive,
                                       isConstrained: nwPath.isConstrained)
            Task { @MainActor in
                guard let self, self.path != path else { return }
                self.path = path
                self.onChange?(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "software.tactile.texts.sync.network"))
    }

    deinit { monitor.cancel() }
}
