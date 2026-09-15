/// The embedded 56-host directory table (architecture §4.1).
///
/// The data itself is generated from `research/host-table.json` into
/// `HostTableData.swift` by `Scripts/generate-host-table.sh`; regenerate rather
/// than editing by hand. `HostTableTests` asserts the count and JSON parity.
public enum HostTable {
    /// All 56 host specifications, in the source table's order.
    public static let hosts: [HostSpec] = generatedHosts

    /// Looks up a host by its stable id.
    public static func host(id: String) -> HostSpec? {
        hosts.first { $0.id == id }
    }
}
