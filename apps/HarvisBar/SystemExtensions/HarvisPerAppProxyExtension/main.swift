import Dispatch
import NetworkExtension

if #available(macOS 15.0, *) {
    NEProvider.startSystemExtensionMode()
    dispatchMain()
}
