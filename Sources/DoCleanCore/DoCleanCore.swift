import Foundation

/// Core engine of do clean: rules, scanning, safety checks and cleaning.
public enum DoCleanCore {
    public static let version = "1.0.0"

    /// Bundle that holds the declarative rule catalog (`Rules/*.json`).
    public static var resourceBundle: Bundle { .module }
}
