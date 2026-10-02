import SukiruCore
import SwiftUI

/// Inspects the selected finding: the implicated skill's full inspector when
/// there is one, otherwise the problem's explanation and evidence.
struct HealthDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let finding = state.selectedFinding() {
            if let skill = state.skill(matching: finding) {
                SkillDetailForm(skill: skill)
                    .id(skill.selfID)
            } else {
                FindingDetailForm(finding: finding)
            }
        } else {
            ContentUnavailableView {
                Label("Select a problem to inspect it", systemImage: "stethoscope")
            }
        }
    }
}

private struct FindingDetailForm: View {
    let finding: Finding

    var body: some View {
        let kind = ProblemKind.of(finding)
        Form {
            Section {
                Text(kind.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caution = finding.removalCaution {
                    Text(verbatim: caution)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: finding.title)
                        .font(.title.weight(.semibold))
                    Label(kind.title, systemImage: kind.symbol)
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            if !finding.evidence.isEmpty {
                Section("Evidence") {
                    ForEach(Array(finding.evidence.enumerated()), id: \.offset) { pair in
                        LabeledContent(EvidencePresentation.label(forKind: pair.element.kind)) {
                            Text(verbatim: EvidencePresentation.detail(of: pair.element))
                                .font(.callout.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}
