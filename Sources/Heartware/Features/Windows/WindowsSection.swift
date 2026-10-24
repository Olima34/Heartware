import SwiftUI
import AppKit

/// The Fenêtres part of the Raccourcis page: every layout with its shortcut in two columns, then the few settings.
struct WindowsSection: View {
    @Environment(AppModel.self) private var app
    static var tint: Color { Theme.palette[6] }

    static let tip = HelpTip(
        id: "hotkeys.windows",
        title: "Ranger tes fenêtres au clavier",
        text: "Un raccourci range la fenêtre au premier plan, dans l'app où tu es. Appuie encore sur une moitié : elle passe à ⅔ puis à ⅓. « Taille précédente » la remet comme avant.",
        steps: ["Autorise l'Accessibilité : macOS l'exige pour déplacer les fenêtres des autres apps.",
                "Essaie ⌃⌥← puis ⌃⌥→ sur n'importe quelle fenêtre.",
                "Sans raccourci, tape « gauche » ou « plein écran » dans le lanceur."])

    var body: some View {
        let model = app.windows
        VStack(alignment: .leading, spacing: 12) {
            if !model.trusted {
                WindowsPermissionLine()
            } else if !model.enabled {
                WindowsNotice(symbol: "pause.circle", text: "En pause : ces raccourcis sont libérés pour les autres apps.", tint: Theme.text3)
            }
            if let refusal = model.refusal {
                WindowsNotice(symbol: "exclamationmark.triangle", text: refusal, tint: Theme.warn)
            }
            if let note = model.note {
                WindowsNotice(symbol: "arrow.triangle.swap", text: note, tint: Self.tint)
            }
            Card(padding: 14) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        WindowsGroupList(group: .halves)
                        WindowsGroupList(group: .quarters)
                        WindowsGroupList(group: .displays)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        WindowsGroupList(group: .thirds)
                        WindowsGroupList(group: .size)
                    }
                }
                Divider().overlay(Theme.border)
                WindowsSettingsLine()
            }
        }
        .onAppear { model.refreshTrust() }
    }
}

/// What sits next to the page's tabs while Fenêtres is shown: its tip and the main switch.
struct WindowsToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.windows
        HStack(spacing: 12) {
            HelpTipButton(tip: WindowsSection.tip)
            Toggle(isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })) {
                Text("Raccourcis actifs").font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
            }
            .switchToggles()
            .fixedSize()
        }
    }
}

/// One line, only while the permission is missing; macOS is asked on the click, never before.
private struct WindowsPermissionLine: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        WindowsNotice(symbol: "hand.raised", text: "Autorise l'Accessibilité : Heartware en a besoin pour déplacer tes fenêtres, rien d'autre.", tint: Theme.warn) {
            Button("Autoriser") { AppPermission.accessibility.request() }
                .buttonStyle(SoftButtonStyle(prominent: true, small: true))
            Button("C'est fait") {
                app.windows.refreshTrust()
                if !app.windows.trusted, !DemoData.isEnabled {
                    HUD.show("Pas encore : coche Heartware dans Réglages Système › Accessibilité", symbol: "hand.raised")
                }
            }
            .buttonStyle(SoftButtonStyle(small: true))
        }
        .help("macOS ne laisse une app déplacer les fenêtres des autres qu'avec cette autorisation. Heartware lit seulement la position et la taille de la fenêtre au premier plan, et les change quand tu le demandes.")
    }
}

/// A slim line above the list: a state to know about, and what to do about it.
struct WindowsNotice<Trailing: View>: View {
    var symbol: String
    var text: String
    var tint: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if Theme.icons != .hidden {
                Image(systemName: symbol)
                    .font(.ui(12.5, .medium))
                    .foregroundStyle(Theme.icons == .tinted ? tint : Theme.text2)
            }
            Text(text).font(.ui(12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: Theme.line))
    }
}

extension WindowsNotice where Trailing == EmptyView {
    init(symbol: String, text: String, tint: Color) {
        self.init(symbol: symbol, text: text, tint: tint) { EmptyView() }
    }
}

/// One family of layouts under a small title (its remark, if any, as a tooltip).
private struct WindowsGroupList: View {
    var group: WindowsGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title.uppercased())
                .font(.ui(10, .semibold))
                .tracking(0.7)
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
                .help(group.subtitle ?? "")
            ForEach(group.actions) { a in
                WindowsActionRow(action: a)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A layout: its drawing, its name, its shortcut and a button to try it.
private struct WindowsActionRow: View {
    @Environment(AppModel.self) private var app
    var action: WindowsAction

    var body: some View {
        let model = app.windows
        let cycling = action == .leftHalf || action == .rightHalf
        HotkeysHoverRow {
            HStack(spacing: 10) {
                WindowsMiniScreen(action: action, width: 32)
                Text(action.title).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                if model.isRefused(action) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.ui(11))
                        .foregroundStyle(Theme.bad)
                        .help("macOS ou une autre app utilise déjà ce raccourci : choisis-en un autre.")
                }
                ShortcutRecorder(combo: model.combos[action]) { model.setCombo($0, for: action) }
                Button {
                    if let m = model.perform(action, pid: ProcessInfo.processInfo.processIdentifier).message {
                        HUD.show(m, symbol: "exclamationmark.triangle.fill")
                    }
                } label: {
                    Image(systemName: "play.circle").font(.ui(14)).foregroundStyle(model.trusted ? Theme.text2 : Theme.text3)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.trusted)
                .help("Essayer sur la fenêtre de Heartware (« Taille précédente » la remet en place)")
            }
        }
        .help((cycling && !model.cycles ? nil : action.detail) ?? "")
    }
}

/// A tiny screen with the area the action fills.
struct WindowsMiniScreen: View {
    var action: WindowsAction
    var width: CGFloat = 40

    var body: some View {
        let h = width * 0.64
        let tint = WindowsSection.tint
        Group {
            if action == .nextDisplay || action == .previousDisplay {
                displays(h)
            } else {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Theme.r(3.5)).fill(Theme.track)
                    RoundedRectangle(cornerRadius: Theme.r(3.5)).strokeBorder(Theme.borderStrong, lineWidth: Theme.line)
                    if let r = WindowsGeometry.preview(action) {
                        let inset: CGFloat = 2.5
                        let w = width - inset * 2, hh = h - inset * 2
                        RoundedRectangle(cornerRadius: Theme.r(2))
                            .fill(action == .restore ? Color.clear : tint)
                            .overlay(RoundedRectangle(cornerRadius: Theme.r(2))
                                .strokeBorder(tint, style: StrokeStyle(lineWidth: 1, dash: action == .restore ? [2, 1.5] : [])))
                            .frame(width: max(2, r.width * w - 1), height: max(2, r.height * hh - 1))
                            .offset(x: inset + r.minX * w + 0.5, y: inset + r.minY * hh + 0.5)
                    }
                    if action == .restore {
                        Image(systemName: "arrow.uturn.backward").font(.ui(8, .bold)).foregroundStyle(tint)
                            .frame(width: width, height: h)
                    }
                }
                .frame(width: width, height: h)
            }
        }
    }

    private func displays(_ h: CGFloat) -> some View {
        let small = width * 0.42
        return HStack(spacing: 0) {
            screen(filled: action == .previousDisplay, side: small)
            Image(systemName: action == .nextDisplay ? "arrow.right" : "arrow.left")
                .font(.ui(7, .bold)).foregroundStyle(Theme.text3)
                .frame(width: width - small * 2)
            screen(filled: action == .nextDisplay, side: small)
        }
        .frame(width: width, height: h)
    }

    private func screen(filled: Bool, side: CGFloat) -> some View {
        let tint = WindowsSection.tint
        return RoundedRectangle(cornerRadius: Theme.r(2.5))
            .fill(filled ? tint : Theme.track)
            .overlay(RoundedRectangle(cornerRadius: Theme.r(2.5)).strokeBorder(filled ? tint : Theme.borderStrong, lineWidth: 1))
            .frame(width: side, height: side * 0.7)
    }
}

/// The margin, the ½ → ⅔ → ⅓ cycle and the way back to the default keys, on one line under the list.
private struct WindowsSettingsLine: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.windows
        HStack(spacing: 12) {
            Text("Marge").font(.ui(12)).foregroundStyle(Theme.text2)
            PillPicker(options: WindowsGap.allCases,
                       selection: Binding(get: { model.gap }, set: { model.setGap($0) }),
                       label: { $0.title })
                .help("L'espace laissé entre les fenêtres et autour d'elles")
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { model.cycles }, set: { model.setCycles($0) })) {
                Text("Moitiés : ½ → ⅔ → ⅓").font(.ui(12)).foregroundStyle(Theme.text)
            }
            .switchToggles()
            .fixedSize()
            .help("Appuie de nouveau sur Moitié gauche ou droite : la fenêtre passe à ⅔, puis à ⅓.")
            Button("Raccourcis par défaut") { model.resetShortcuts() }
                .buttonStyle(SoftButtonStyle(small: true))
        }
    }
}
