import Yams

/// Namespace for the Sukiru read/repair engine.
///
/// The concrete Seam A / Seam B components land in later milestones; this
/// skeleton anchors the module and confirms that the sole external
/// dependency (Yams) links and parses YAML.
public enum SukiruCore {
    /// Stable identifier surfaced to consumers during the skeleton milestone.
    public static let identifier = "sukiru-core"

    /// Confirms the Yams dependency is linked and can parse YAML.
    ///
    /// Returns `true` when a trivial document loads without throwing.
    public static func yamsAvailable() -> Bool {
        (try? Yams.load(yaml: "ok: true")) != nil
    }
}
