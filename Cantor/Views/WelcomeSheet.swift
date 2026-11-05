import CantorCore
import SwiftUI

/// The one question a fresh install asks: where services come from. Changeable later in
/// Settings > Services. Choosing Planning Center turns Claude on, as before this choice existed.
struct WelcomeSheet: View {
    @AppEnvironment private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Cantator").font(.title.weight(.semibold))
                Text("How will your services get into Cantator? You can change this any time in Settings > Services.")
                    .foregroundStyle(.secondary)
            }
            choice(
                title: "I'll build them here", symbol: "calendar.badge.plus",
                detail: "No accounts to sign in to. Make a service, drag your tracks in, and run it. Nothing leaves this Mac. Claude stays off unless you turn it on in Settings."
            ) {
                model.chooseServiceSource(.standalone)
            }
            choice(
                title: "From Planning Center", symbol: "calendar",
                detail: "Sync the plan and match items to your files. Needs a Planning Center sign-in. Claude is turned on to help match, and can be turned off in Settings."
            ) {
                model.chooseServiceSource(.planningCenter)
            }
            Text("Next: choose your house and cue outputs in Settings. The Pre-Service Check will remind you.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled()
    }

    private func choice(title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBrighten()
    }
}
