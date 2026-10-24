import SwiftUI

/// The profile panel in the middle of the main window, like the first-launch cards. A click beside it, Esc or
/// « Terminé » closes it: every change is already applied.
struct ProfileModal: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            // The only fixed color: a veil that darkens whatever theme is behind it.
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture { app.showProfilePanel = false }
            ProfilePanel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .ignoresSafeArea()
    }
}

struct ProfilePanel: View {
    static let width: CGFloat = 720
    static let height: CGFloat = 664

    @Environment(AppModel.self) private var app

    var body: some View {
        let profile = app.profile
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TON PROFIL")
                    .font(.ui(10.5, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text3)
                Text("Une app à ta mesure")
                    .font(.serif(25))
                    .foregroundStyle(Theme.text)
                Text("Coche ce qui te ressemble, même plusieurs : je mets tes outils en avant et je range les autres, en bas de la barre latérale.")
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)

            ProfileKindGrid(columns: 3)
                .padding(.horizontal, 26)
                .padding(.top, 14)

            HStack(alignment: .firstTextBaseline) {
                Text("DANS TA BARRE LATÉRALE")
                    .font(.ui(10.5, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text3)
                Spacer()
                if profile.isCustomised {
                    Button("Annuler mes ajouts et retraits") { profile.resetChoices() }
                        .buttonStyle(.plain)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.accent)
                        .help("Revenir à ce que ton profil et ton usage décident")
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 16)
            .padding(.bottom, 6)

            ScrollArea {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 2) {
                    ForEach(Page.groups.flatMap(\.1).filter { $0 != .dashboard }) { ProfileToolRow(page: $0) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(Theme.border).frame(height: Theme.line)
            HStack(alignment: .center, spacing: 14) {
                Text("Je m'adapte aussi à toi : un outil que tu ouvres plusieurs jours rejoint la barre, un outil de ton profil oublié depuis \(ToolProfileRules.fadeDays) jours se range. La barre \(app.launcher.combo?.display ?? "⌥Espace") trouve toujours tout.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Terminé") { app.showProfilePanel = false }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background(keys)
        }
        .frame(width: Self.width, height: Self.height)
        .floatingSurface(radius: 20)
    }

    /// Esc closes it.
    private var keys: some View {
        Button("") { app.showProfilePanel = false }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// The profiles as tiles to tick, several at once. Shared by the panel and the first-launch card.
struct ProfileKindGrid: View {
    var columns = 3
    @Environment(AppModel.self) private var app

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns), spacing: 10) {
            ForEach(Array(ToolProfileKind.allCases.enumerated()), id: \.element) { i, kind in
                ProfileKindTile(kind: kind, index: i, on: app.profile.settings.kinds.contains(kind)) {
                    app.profile.toggle(kind)
                }
            }
        }
    }
}

struct ProfileKindTile: View {
    var kind: ToolProfileKind
    var index: Int
    var on: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(symbol: kind.symbol, tint: Theme.color(index: index), size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.ui(13, .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.trailing, 20)
                    Text(kind.blurb)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .overlay(alignment: .topTrailing) {
                CheckBox(state: on ? .on : .off, action: action).padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous)
                .fill(on ? Theme.selected : (hovering ? Theme.hover : Theme.card)))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous)
                .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? max(1.5, Theme.line) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A tool, ticked when it is in the sidebar, with the reason it is there (or not).
struct ProfileToolRow: View {
    var page: Page
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let reason = app.profile.reason(page)
        let featured = reason.featured
        Button { app.profile.setFeatured(page, !featured) } label: {
            HStack(spacing: 9) {
                CheckBox(state: featured ? .on : .off) { app.profile.setFeatured(page, !featured) }
                if Theme.icons != .hidden {
                    Image(systemName: page.symbol)
                        .font(.ui(12))
                        .foregroundStyle(featured ? Theme.text2 : Theme.text3)
                        .frame(width: 18)
                }
                Text(page.title)
                    .font(.ui(12.5))
                    .foregroundStyle(featured ? Theme.text : Theme.text2)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Tag(text: reason.label, tint: tint(reason), filled: emphasised(reason))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(page.pitch)\n\(reason.detail)")
    }

    private func tint(_ r: ToolReason) -> Color {
        switch r {
        case .used, .active: return Theme.good
        case .pinned, .profile: return Theme.accent
        case .faded: return Theme.warn
        default: return Theme.text3
        }
    }

    /// What the app decided from the user's habits stands out.
    private func emphasised(_ r: ToolReason) -> Bool {
        switch r {
        case .used, .active, .pinned, .faded: return true
        default: return false
        }
    }
}

/// The dashboard's invitation to choose a profile, until one is chosen or it is closed.
struct ProfileInvite: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .center, spacing: 14) {
                IconBadge(symbol: "person.crop.rectangle.stack", tint: Theme.brand, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Une app à ta mesure").font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    Text("Choisis ton profil : je mets en avant les outils qui te servent.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.text2)
                }
                Spacer(minLength: 8)
                Button("Plus tard") { app.profile.dismissInvite() }
                    .buttonStyle(SoftButtonStyle())
                    .help("Tu le retrouves sous le nom de l'app, dans la barre latérale.")
                Button("Choisir mon profil") { app.showProfilePanel = true }
                    .buttonStyle(SoftButtonStyle(prominent: true))
            }
        }
    }
}
