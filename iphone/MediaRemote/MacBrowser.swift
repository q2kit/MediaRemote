import Foundation
import Network

struct DiscoveredMac: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Finds Macs running Media Remote on the local network via Bonjour.
final class MacBrowser: ObservableObject {
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var problem: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: RemoteService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.macs = results
                .compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredMac(name: name, endpoint: result.endpoint)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                problem = nil
            case .waiting:
                // Typically means Local Network access was denied.
                problem = String(localized: "Allow Local Network access for the app in Settings › Privacy & Security › Local Network.")
            case .failed(let error):
                problem = error.localizedDescription
                stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
