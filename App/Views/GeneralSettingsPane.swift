import SwiftUI

/// App-wide preferences, such as the UI language override.
struct GeneralSettingsPane: View {
    @State private var language = AppLanguage.override

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(AppLanguage.available, id: \.self) { identifier in
                        Text(verbatim: AppLanguage.displayName(identifier))
                            .tag(Optional(identifier))
                    }
                }
            } footer: {
                if AppLanguage.needsRelaunch(for: language) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Sukiru switches to the new language after it relaunches.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Relaunch Now") {
                            AppLanguage.relaunch()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 160)
        .onChange(of: language) { _, newValue in
            AppLanguage.override = newValue
        }
    }
}
