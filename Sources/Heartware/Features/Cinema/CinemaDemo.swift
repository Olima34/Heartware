import SwiftUI

/// The demo's titles: invented films and series, people and addresses (never a real title).
enum CinemaDemo {
    static let hits: [CinemaHit] = [
        CinemaHit(kind: .movie, tmdbID: 900_101, title: "Les Marées d'Ouessant", originalTitle: nil, year: 2023,
                  overview: "Gardienne du dernier phare habité de l'île, Maëlle voit arriver un cartographe chargé de l'automatiser. Un hiver de tempêtes, de relevés et de silences les oblige à cohabiter.",
                  posterPath: "/demo-marees.jpg", rating: 7.6, votes: 2_418),
        CinemaHit(kind: .tv, tmdbID: 900_202, title: "Marée basse", originalTitle: "Low Tide", year: 2021,
                  overview: "Dans un port de pêche du Finistère, une enquêtrice revient dans sa ville natale quand un chalutier rentre sans son équipage.",
                  posterPath: "/demo-maree-basse.jpg", rating: 8.1, votes: 964),
        CinemaHit(kind: .movie, tmdbID: 900_303, title: "La Marée des étoiles", originalTitle: nil, year: 2019,
                  overview: "Un renard des sables et une luciole perdue suivent la marée qui, une nuit par siècle, monte jusqu'au ciel.",
                  posterPath: "/demo-etoiles.jpg", rating: 7.2, votes: 5_120),
        CinemaHit(kind: .movie, tmdbID: 900_404, title: "Marée haute, cœur battant", originalTitle: nil, year: 2016,
                  overview: "Deux moniteurs de char à voile rivaux doivent organiser ensemble le festival de leur plage.",
                  posterPath: "/demo-maree-haute.jpg", rating: 6.1, votes: 312),
        CinemaHit(kind: .movie, tmdbID: 900_505, title: "Après la marée", originalTitle: nil, year: 2008,
                  overview: "Le dernier été d'une conserverie de sardines, raconté par ses ouvrières.",
                  posterPath: "/demo-apres.jpg", rating: 6.8, votes: 88)
    ]

    static var titles: [CinemaTitle] {
        var first = CinemaTitle(hit: hits[0])
        first.tagline = "Certaines lumières ne s'éteignent pas."
        first.genres = ["Drame", "Romance"]
        first.runtime = 112
        first.makers = ["Inès Kervella"]
        first.cast = ["Lou Talec", "Bastien Morvan", "Odile Ferrec", "Yann Le Guen"]
        first.trailer = "Xy7Pq2LmN4a"
        first.offers = [
            CinemaOffer(kind: .subscription, providerID: 8, name: "Netflix", priority: 1),
            CinemaOffer(kind: .subscription, providerID: 381, name: "Canal+", priority: 3),
            CinemaOffer(kind: .rent, providerID: 2, name: "Apple TV", priority: 4),
            CinemaOffer(kind: .rent, providerID: 3, name: "Google Play Movies", priority: 9),
            CinemaOffer(kind: .buy, providerID: 2, name: "Apple TV", priority: 4)
        ]
        first.watchPage = "https://www.themoviedb.org/movie/900101/watch?locale=FR"
        first.direct = ["netflix": "https://www.netflix.com/title/80990101"]
        first.wikidataChecked = true

        var second = CinemaTitle(hit: hits[1])
        second.genres = ["Policier", "Drame"]
        second.runtime = 52
        second.seasons = 2
        second.episodes = 12
        second.makers = ["Gaëlle Riou"]
        second.cast = ["Anna Le Bihan", "Malo Kerjean"]
        second.offers = [CinemaOffer(kind: .free, providerID: 236, name: "France TV", priority: 2),
                         CinemaOffer(kind: .subscription, providerID: 337, name: "Disney Plus", priority: 2)]

        var third = CinemaTitle(hit: hits[2])
        third.genres = ["Animation", "Familial"]
        third.runtime = 88
        third.offers = [CinemaOffer(kind: .ads, providerID: 192, name: "YouTube", priority: 5),
                        CinemaOffer(kind: .rent, providerID: 119, name: "Amazon Prime Video", priority: 2)]

        var last = CinemaTitle(hit: hits[4])
        last.genres = ["Documentaire"]
        last.runtime = 74
        return [first, second, third, last]
    }
}

/// An invented poster for the demo: the title over a gradient of the theme, a horizon and a sun.
struct CinemaDemoPoster: View {
    var hit: CinemaHit

    var body: some View {
        let seed = hit.tmdbID
        let top = Theme.color(index: seed)
        let bottom = Theme.color(index: seed / 7 + 2)
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
                Circle().fill(Theme.ink(on: top).opacity(0.22))
                    .frame(width: geo.size.width * 0.5)
                    .position(x: geo.size.width * 0.66, y: geo.size.height * 0.36)
                Rectangle().fill(Theme.ink(on: bottom).opacity(0.18))
                    .frame(height: geo.size.height * 0.3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Text(hit.title)
                    .font(.serif(max(8, geo.size.width * 0.13)))
                    .foregroundStyle(Theme.ink(on: bottom))
                    .lineLimit(3).minimumScaleFactor(0.5)
                    .padding(geo.size.width * 0.08)
            }
        }
    }
}
