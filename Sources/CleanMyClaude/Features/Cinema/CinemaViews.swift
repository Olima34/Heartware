import SwiftUI

// MARK: - Pictures

/// A title's poster: TMDB's picture, drawn in the demo, its kind while it loads.
struct CinemaPoster: View {
    @Environment(AppModel.self) private var app
    var hit: CinemaHit
    var width = 185
    var corner: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if DemoData.isEnabled {
                    CinemaDemoPoster(hit: hit)
                } else if let cg = app.cinema.picture(hit.posterPath, width: width) {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.high).scaledToFill()
                } else {
                    ZStack {
                        Theme.track
                        if Theme.icons != .hidden {
                            Image(systemName: hit.kind.symbol).font(.ui(18)).foregroundStyle(Theme.text3)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.r(corner)))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(corner)).strokeBorder(Theme.border, lineWidth: Theme.line))
            .onAppear { app.cinema.loadPicture(hit.posterPath, width: width) }
    }
}

/// A platform's logo (TMDB's), or its initial on a color of the theme.
struct CinemaLogo: View {
    @Environment(AppModel.self) private var app
    var offer: CinemaOffer
    var size: CGFloat = 16

    var body: some View {
        Group {
            if !DemoData.isEnabled, let cg = app.cinema.picture(offer.logoPath, width: 92) {
                Image(decorative: cg, scale: 1).resizable().interpolation(.high).scaledToFill()
            } else {
                let fill = Theme.color(index: offer.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
                ZStack {
                    fill
                    Text(String(offer.displayName.prefix(1)))
                        .font(.ui(size * 0.58, .bold)).foregroundStyle(Theme.ink(on: fill))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.r(size * 0.25)))
    }
}

// MARK: - Where to watch

struct CinemaOfferChip: View {
    @Environment(AppModel.self) private var app
    var offer: CinemaOffer
    var title: CinemaTitle

    var body: some View {
        let model = app.cinema
        let mine = offer.platform.map { model.mine.contains($0.key) } ?? false
        Button { model.open(offer, in: title) } label: {
            HStack(spacing: 5) {
                CinemaLogo(offer: offer, size: 16)
                Text(offer.displayName).font(.ui(11.5, .medium)).lineLimit(1)
                if mine {
                    Image(systemName: "checkmark.circle.fill").font(.ui(9.5)).foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.leading, 4).padding(.trailing, 8).frame(height: 24)
            .chipGround(false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var help: String {
        let d = CinemaOffers.destination(offer, in: title)
        let name = offer.displayName
        switch d.via {
        case .direct: return "Ouvre « \(title.hit.title) » sur \(name)" + (d.adFreePlayer ? ", dans le lecteur sans pub" : "")
        case .search: return "Cherche « \(title.hit.title) » sur \(name)" + (d.adFreePlayer ? ", dans le lecteur sans pub" : "")
        case .tmdb: return "Ouvre la page TMDB du titre : elle mène à \(name)"
        }
    }
}

/// The platforms of a title, by kind of offer: the user's own first.
struct CinemaOffersView: View {
    @Environment(AppModel.self) private var app
    var title: CinemaTitle
    var compact = false

    var body: some View {
        let offers = CinemaOffers.sorted(title.offers, mine: app.cinema.mine)
        if offers.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Pas en streaming \(CinemaRegion.inName(title.region)) pour l'instant (ni abonnement, ni location, ni achat).")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                Button("Voir la fiche sur TMDB") { Finder.open(title.hit.tmdbURL) }
                    .buttonStyle(.plain).font(.ui(11.5, .medium)).foregroundStyle(Theme.accent)
            }
        } else {
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                ForEach(CinemaOffersView.groups(offers, compact: compact), id: \.label) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.label.uppercased())
                            .font(.ui(9.5, .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
                        FlowLayout(spacing: 5, lineSpacing: 5) {
                            ForEach(group.offers) { CinemaOfferChip(offer: $0, title: title) }
                            if group.more > 0 {
                                Text("+\(group.more)").font(.ui(11, .medium)).foregroundStyle(Theme.text3)
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                                    .help("⌘↩ ouvre la fiche complète avec toutes les boutiques")
                            }
                        }
                    }
                }
            }
        }
    }
}

extension CinemaOffersView {
    struct Group {
        var label: String
        var offers: [CinemaOffer]
        var more = 0
    }

    /// By kind of offer. In the launcher, rental and purchase share one row (the same stores often do both: once each)
    /// and a few stores are shown, the user's first.
    static func groups(_ offers: [CinemaOffer], compact: Bool) -> [Group] {
        var out: [Group] = []
        for kind in [CinemaOfferKind.subscription, .free, .ads] {
            let list = offers.filter { $0.kind == kind }
            if !list.isEmpty { out.append(Group(label: kind.label, offers: list)) }
        }
        let paid = offers.filter { $0.kind == .rent || $0.kind == .buy }
        guard !paid.isEmpty else { return out }
        if compact {
            var seen = Set<String>()
            let stores = paid.filter { seen.insert($0.displayName).inserted }
            let kinds = Set(paid.map(\.kind))
            let label = kinds.count == 2 ? "Location ou achat" : (kinds.first?.label ?? "Location")
            out.append(Group(label: label, offers: Array(stores.prefix(5)), more: max(0, stores.count - 5)))
        } else {
            for kind in [CinemaOfferKind.rent, .buy] {
                let list = paid.filter { $0.kind == kind }
                if !list.isEmpty { out.append(Group(label: kind.label, offers: list)) }
            }
        }
        return out
    }
}

enum CinemaRegion {
    /// The countries offered in « Pays » (TMDB has the platforms of each).
    static let choices = ["FR", "BE", "CH", "LU", "CA", "ES", "PT", "IT", "DE", "GB", "US", "MA"]

    static var system: String {
        let r = Locale.current.region?.identifier.uppercased() ?? "FR"
        return isValid(r) ? r : "FR"
    }

    static func isValid(_ code: String) -> Bool { code.count == 2 && code.allSatisfy { $0.isASCII && $0.isUppercase } }

    static func name(_ code: String) -> String { Fmt.fr.localizedString(forRegionCode: code) ?? code }

    /// « en France », « au Canada », « en Belgique »: the region's name with a plain preposition.
    static func inName(_ code: String) -> String {
        let name = name(code)
        let masculine: Set<String> = ["CA", "LU", "MA", "JP", "BR", "PT", "MX", "SN", "CM", "DK", "VN"]
        if ["US", "NL"].contains(code) { return "aux " + name }
        return (masculine.contains(code) ? "au " : "en ") + name
    }
}

// MARK: - A title's card

struct CinemaTitleCard: View {
    @Environment(AppModel.self) private var app
    var hit: CinemaHit
    var compact = false

    var body: some View {
        let model = app.cinema
        let t = model.title(hit)
        let shown = t?.hit ?? hit
        VStack(alignment: .leading, spacing: compact ? 9 : 14) {
            HStack(alignment: .top, spacing: compact ? 11 : 18) {
                CinemaPoster(hit: shown, width: compact ? 185 : 342, corner: compact ? 6 : 10)
                    .frame(width: compact ? 70 : 150)
                VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                    Text(shown.title)
                        .font(compact ? .ui(14, .semibold) : .serif(24)).foregroundStyle(Theme.text)
                        .lineLimit(compact ? 2 : 3).fixedSize(horizontal: false, vertical: true)
                    if let original = shown.originalTitle {
                        Text(original).font(.ui(compact ? 10.5 : 12)).italic().foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Text(t.map(CinemaFormat.facts) ?? shown.line)
                        .font(.ui(compact ? 11 : 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let r = shown.rating, shown.votes >= 20 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.ui(compact ? 9 : 10)).foregroundStyle(Theme.warn)
                            Text(CinemaFormat.rating(r) + " / 10").font(.ui(compact ? 11 : 12, .medium)).foregroundStyle(Theme.text)
                            Text("· " + Fmt.plural(shown.votes, "avis", "avis") + " sur TMDB").font(.ui(compact ? 10.5 : 11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    if !compact, let t {
                        if let tagline = t.tagline {
                            Text("« \(tagline) »").font(.serif(14)).italic().foregroundStyle(Theme.text2)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                        }
                        people(t).padding(.top, 2)
                        if t.trailer != nil {
                            Button { model.playTrailer(t) } label: {
                                Label("Bande-annonce sans pub", systemImage: "play.rectangle")
                            }
                            .buttonStyle(SoftButtonStyle(small: true))
                            .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            let overview = shown.overview.isEmpty ? hit.overview : shown.overview
            if !overview.isEmpty {
                Text(overview)
                    .font(.ui(compact ? 11.5 : 12.5)).foregroundStyle(Theme.text2)
                    .lineLimit(compact ? 4 : nil).fixedSize(horizontal: false, vertical: true)
            }
            if compact, let t, !(t.makers.isEmpty && t.cast.isEmpty) {
                people(t).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Où regarder \(CinemaRegion.inName(t?.region ?? model.region))")
                    .font(.ui(compact ? 11.5 : 13, .semibold)).foregroundStyle(Theme.text)
                if let t {
                    CinemaOffersView(title: t, compact: compact)
                } else if let error = model.titleErrors[hit.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(11)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    Button("Réessayer") { model.load(hit) }.buttonStyle(SoftButtonStyle(small: true))
                } else {
                    HStack(spacing: 6) {
                        BusyMascot(.searching, pixel: 1)
                        Text("Recherche des plateformes…").font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
    }

    private func people(_ t: CinemaTitle) -> some View {
        var parts: [String] = []
        if !t.makers.isEmpty { parts.append((t.hit.kind == .movie ? "De " : "Créée par ") + t.makers.joined(separator: ", ")) }
        if !t.cast.isEmpty { parts.append("avec " + t.cast.prefix(compact ? 3 : 5).joined(separator: ", ")) }
        return Text(parts.joined(separator: " · "))
            .font(.ui(compact ? 11 : 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Launcher

/// At the right of the launcher while a title is selected: its card and where to watch it. ↩ opens the best offer.
struct CinemaLauncherPane: View {
    @Environment(AppModel.self) private var app
    var hit: CinemaHit

    var body: some View {
        let model = app.cinema
        VStack(alignment: .leading, spacing: 8) {
            ScrollArea(showsIndicators: false) {
                CinemaTitleCard(hit: hit, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(hints(model.bestOffer(hit)))
                .lineLimit(1).font(.ui(10.5)).foregroundStyle(Theme.text3)
        }
        .padding(14)
        .task(id: hit.id) {
            // Arrowing through the list asks only for the title it stops on.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            model.load(hit)
        }
    }

    private func hints(_ offer: CinemaOffer?) -> String {
        let watch = offer.map { "↩ Regarder sur \($0.displayName)" } ?? "↩ Où regarder"
        return watch + " · ⌘↩ Fiche complète"
    }
}

/// The « Films et séries » row of any text, and the wait of a search: the best match's card once TMDB answers.
struct CinemaSearchPane: View {
    @Environment(AppModel.self) private var app
    var title: String
    var kind: CinemaKind?

    var body: some View {
        let model = app.cinema
        let state = model.search(title, kind: kind)
        let hits = state?.hits ?? []
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .done(let found, _) where !found.isEmpty:
                ScrollArea(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        CinemaTitleCard(hit: found[0], compact: true)
                        if found.count > 1 {
                            Text("Aussi : " + found.dropFirst().prefix(4).map { h in h.year.map { "\(h.title) (\($0))" } ?? h.title }.joined(separator: " · "))
                                .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .done:
                Text("Aucun film ni série « \(title) » sur TMDB.").font(.ui(12)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            default:
                HStack(spacing: 8) {
                    BusyMascot(.searching, pixel: 1.5)
                    Text("Recherche de « \(title) »…").font(.ui(12)).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
            }
            Text(hits.isEmpty ? "↩ Tous les résultats" : "↩ Tous les résultats · " + (model.bestOffer(hits[0]).map { "sur \($0.displayName)" } ?? "où regarder"))
                .lineLimit(1).font(.ui(10.5)).foregroundStyle(Theme.text3)
        }
        .padding(14)
        .task(id: CinemaQuery.key(title, kind: kind)) {
            // Selecting the row is the request: asked once it stays selected a moment.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            model.startSearch(title, kind: kind, delay: 0, forLauncher: true)
        }
        .task(id: hits.first?.id) {
            if let first = hits.first { model.load(first) }
        }
    }
}
