import AppKit
import Foundation

extension HarvisRuntimeModel {
    func digitalMeStudioURL(
        _ destination: DigitalMeStudioDestination
    ) -> URL? {
        localURL(
            path: "/studio/",
            extraQueryItems: [
                URLQueryItem(name: "view", value: destination.rawValue),
            ]
        )
    }

    @discardableResult
    func openDigitalMeStudio(_ destination: DigitalMeStudioDestination) -> Bool {
        guard let url = digitalMeStudioURL(destination) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
