import SwiftUI
import ClaudeKit

/// Native OAuth remains an explicit user action; a cached identity never means ready.
struct ClaudeCLIConnectionView: View {
    let plan: ClaudeCLIConnectionPlan
    let membershipName: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Claude Code").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(membershipName).font(.headline)
                if let email = plan.email { Text(email).foregroundStyle(.secondary) }
            }
            if plan.hasWrongMembership {
                Label("Wrong CLI membership. Finish its work before reconnecting.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if plan.cachedIdentity != nil {
                Text("A saved CLI identity exists. Its sign-in and limits still need verification.")
                    .foregroundStyle(.secondary)
            }
            Text("Run the login command in Terminal, then choose this membership in your browser.")
            Text("Desktop sign-in and remote-host sign-in are separate.")
                .foregroundStyle(.secondary)
            DisclosureGroup("Verify after sign-in") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Check the email and organization in the native status. CLI tasks also check exact identity and fresh limits before starting.")
                    Text("\(plan.organization)\nOrganization: \(plan.organizationUuid)")
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy status command") { copy(plan.verificationCommand, label: "Status command copied") }
                }
                .padding(.top, 8)
            }
            HStack {
                if let copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy login command") { copy(plan.command, label: "Login command copied") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 440)
    }

    private func copy(_ command: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = label
    }
}
