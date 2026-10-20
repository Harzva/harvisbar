import Foundation

/// Studio views that the compact Digital-Me navigation is allowed to open.
/// Keeping this list typed prevents arbitrary query values from entering links.
enum DigitalMeStudioDestination: String, CaseIterable, Equatable, Sendable {
    case work
    case review
    case memory
    case personaEditor = "studio"
    case copyMeBuilder = "copy"
}
