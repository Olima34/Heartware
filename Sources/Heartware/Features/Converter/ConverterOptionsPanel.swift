import SwiftUI

/// The settings of the operation chosen in the Convertisseur's window: a label on the left, chips and sliders on the right.
struct ConverterOptionsForm: View {
    @Bindable var model: ConverterModel
    var op: ConverterOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let count = model.targets(for: op).count
            if count < op.minimumCount {
                ConverterNote(symbol: "exclamationmark.triangle", text: "Il en faut au moins \(op.minimumCount).", tint: Theme.warn)
            }
            options
        }
    }

    @ViewBuilder
    private var options: some View {
        switch op {
        case .imageConvert:
            ConverterOptionRow(label: "Format") { formatChips(selection: $model.options.imageFormat, includeSame: false) }
            if model.options.imageFormat?.lossy ?? true { qualityRow($model.options.imageQuality) }
            ConverterOptionRow(label: "Métadonnées") {
                ConverterChips(options: [false, true], selection: $model.options.stripOnConvert) { $0 ? "Sans GPS ni métadonnées" : "Gardées" }
            }
        case .imageResize:
            ConverterOptionRow(label: "Côté le plus long") {
                ConverterChips(options: [4096, 3000, 2048, 1600, 1280, 1024, 800, 512], selection: $model.options.maxSide) { "\(Fmt.int($0)) px" }
            }
            ConverterOptionRow(label: "Format") { formatChips(selection: $model.options.resizeFormat, includeSame: true) }
            if model.qualityApplies(op) { qualityRow($model.options.imageQuality) }
        case .imageCompress:
            if model.qualityApplies(op) { qualityRow($model.options.imageQuality) }
            ConverterOptionRow(label: "Format") {
                VStack(alignment: .leading, spacing: 5) {
                    formatChips(selection: $model.options.compressFormat, includeSame: true, lossyOnly: true)
                    losslessNote
                }
            }
            ConverterOptionRow(label: "Taille") {
                ConverterChips(options: [0, 3000, 2048, 1600, 1280], selection: $model.options.compressMaxSide) { $0 == 0 ? "D'origine" : "\(Fmt.int($0)) px" }
            }
        case .imageStrip:
            ConverterOptionRow(label: "Retirer") {
                ConverterChips(options: ConverterStripMode.allCases, selection: $model.options.stripMode) { $0 == .gps ? "La position GPS" : "Toutes les métadonnées" }
            }
        case .imagesToPDF:
            ConverterOptionRow(label: "Pages") {
                ConverterChips(options: ConverterPageSize.allCases, selection: $model.options.pageSize) { $0.title }
            }
            qualityRow($model.options.imageQuality, label: "Qualité des photos")
        case .videoCompress:
            ConverterOptionRow(label: "Réglage", hint: model.options.videoPreset.subtitle) {
                ConverterChips(options: ConverterVideoPreset.allCases, selection: $model.options.videoPreset) { $0.title }
            }
            ConverterOptionRow(label: "Fichier") {
                ConverterChips(options: [ConverterVideoContainer.mp4, .mov], selection: $model.options.compressContainer) { $0.name }
            }
        case .videoContainer:
            ConverterOptionRow(label: "Convertir en") {
                VStack(alignment: .leading, spacing: 5) {
                    ConverterChips(options: model.containers, selection: $model.options.container) { $0.name }
                    if model.ffmpegPath == nil && !DemoData.isEnabled { ConverterNote(symbol: "shippingbox", text: "MKV et WebM : installe ffmpeg (brew install ffmpeg).") }
                }
            }
        case .videoGIF:
            ConverterOptionRow(label: "Largeur") {
                ConverterChips(options: [320, 480, 640, 800], selection: $model.options.gifWidth) { "\($0) px" }
            }
            ConverterOptionRow(label: "Images par seconde") {
                ConverterChips(options: [8, 12, 15, 24], selection: $model.options.gifFPS) { "\($0)" }
            }
            ConverterOptionRow(label: "Durée", hint: "depuis le début") {
                ConverterChips(options: [5, 10, 30, 0], selection: $model.options.gifSeconds) { $0 == 0 ? "Toute la vidéo" : "\($0) s" }
            }
        case .audioConvert:
            ConverterOptionRow(label: "Format") {
                VStack(alignment: .leading, spacing: 5) {
                    ConverterChips(options: model.audioFormats, selection: $model.options.audioFormat) { $0.name }
                    if model.ffmpegPath == nil && !DemoData.isEnabled { ConverterNote(symbol: "shippingbox", text: "MP3 : installe ffmpeg (brew install ffmpeg).") }
                }
            }
            if model.options.audioFormat.lossy {
                ConverterOptionRow(label: "Débit") {
                    ConverterChips(options: [128, 192, 256, 320], selection: $model.options.audioBitrate) { "\($0) kb/s" }
                }
            }
        case .pdfMerge:
            ConverterMergeOptions(model: model)
        case .pdfSplit:
            pagesRow(required: true)
            ConverterOptionRow(label: "Résultat") {
                ConverterChips(options: ConverterSplitMode.allCases, selection: $model.options.splitMode) { $0.title }
            }
        case .pdfRotate:
            ConverterOptionRow(label: "Sens") {
                ConverterChips(options: [90, 180, 270], selection: $model.options.rotation,
                               symbol: { $0 == 90 ? "rotate.right" : ($0 == 180 ? "arrow.uturn.down" : "rotate.left") }) {
                    $0 == 90 ? "90° à droite" : ($0 == 180 ? "180°" : "90° à gauche")
                }
            }
            pagesRow(required: false)
        case .pdfCompress:
            ConverterOptionRow(label: "Niveau", hint: model.options.pdfCompression.subtitle) {
                ConverterChips(options: ConverterPDFCompression.allCases, selection: $model.options.pdfCompression) { $0.title }
            }
        case .pdfToImages:
            ConverterOptionRow(label: "Format") {
                ConverterChips(options: ConverterRasterFormat.allCases, selection: $model.options.rasterFormat) { $0.name }
            }
            ConverterOptionRow(label: "Résolution") {
                ConverterChips(options: [72, 150, 300], selection: $model.options.rasterDPI) { "\($0) ppp" }
            }
            pagesRow(required: false)
        case .documentConvert:
            ConverterOptionRow(label: "Convertir en") {
                ConverterChips(options: ConverterDocFormat.allCases, selection: $model.options.docFormat) { $0.name }
            }
        case .archiveZip:
            ConverterOptionRow(label: "Archives") {
                ConverterChips(options: ConverterZipMode.allCases, selection: $model.options.zipMode) { $0.title }
            }
        case .rename:
            ConverterRenameOptions(model: model)
        case .videoAudio, .archiveExtract, .ocr, .qrRead, .qrGenerate:
            EmptyView()
        }
    }

    /// "Même format" on a PNG (or a TIFF, a GIF…): lossless, the quality changes nothing. Said instead of a useless slider.
    @ViewBuilder
    private var losslessNote: some View {
        let formats = model.writtenFormats(op)
        let lossless = formats.filter { !$0.lossy }
        if model.chosenImageFormat(op) == nil, !lossless.isEmpty {
            let names = lossless.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
            ConverterNote(symbol: "info.circle", text: "\(names) : sans perte, la qualité n'y change rien. JPEG ou HEIC pour vraiment alléger.")
        }
    }

    private func qualityRow(_ value: Binding<Double>, label: String = "Qualité") -> some View {
        ConverterOptionRow(label: label) {
            HStack(spacing: 10) {
                Text("Léger").font(.ui(11)).foregroundStyle(Theme.text3)
                ConverterSlider(value: value, range: 0.3...1)
                Text("Fidèle").font(.ui(11)).foregroundStyle(Theme.text3)
                Text(Fmt.pct(value.wrappedValue)).font(.ui(11).monospacedDigit()).foregroundStyle(Theme.text2).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func formatChips(selection: Binding<ConverterImageFormat?>, includeSame: Bool, lossyOnly: Bool = false) -> some View {
        let formats: [ConverterImageFormat?] = (includeSame ? [nil] : []) + model.imageFormats.filter { !lossyOnly || $0.lossy }.map { $0 }
        return ConverterChips(options: formats, selection: selection) { $0?.name ?? "Même format" }
    }

    private func pagesRow(required: Bool) -> some View {
        let files = model.targets(for: .pdfSplit)
        let counts = files.compactMap(\.pages)
        let smallest = counts.min()
        let parsed = smallest.flatMap { ConverterPDFEngine.parsePages(model.options.pdfPages, count: $0) }
        let empty = model.options.pdfPages.trimmingCharacters(in: .whitespaces).isEmpty
        return ConverterOptionRow(label: "Pages") {
            VStack(alignment: .leading, spacing: 5) {
                ConverterTextField(text: $model.options.pdfPages, prompt: required ? "ex. 1-3, 5, 8-" : "Toutes · ex. 1-3, 5, 8-", symbol: "number", mono: true)
                    .frame(maxWidth: 260)
                if !empty {
                    if let parsed, !parsed.isEmpty {
                        Text("\(Fmt.plural(parsed.count, "page", "pages")) : \(ConverterPDFEngine.describePages(parsed))")
                            .font(.ui(11)).foregroundStyle(Theme.good)
                    } else if let smallest {
                        Text("Je ne comprends pas cette liste (\(Fmt.plural(smallest, "page", "pages")) au plus).")
                            .font(.ui(11)).foregroundStyle(Theme.warn)
                    }
                }
            }
        }
    }
}

/// Pattern, numbering, find and replace, case.
struct ConverterRenameOptions: View {
    @Bindable var model: ConverterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConverterOptionRow(label: "Nouveau nom", hint: "l'extension reste") {
                VStack(alignment: .leading, spacing: 7) {
                    ConverterTextField(text: $model.options.rename.pattern, prompt: "{nom}", symbol: "character.cursor.ibeam", mono: true)
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(ConverterRename.tokens, id: \.token) { t in
                            Button { model.options.rename.pattern += t.token } label: {
                                HStack(spacing: 4) {
                                    Text(t.token).font(.mono(11, .medium)).foregroundStyle(Theme.accent)
                                    Text(t.label).font(.ui(10.5)).foregroundStyle(Theme.text3)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: Theme.r(6)).fill(Theme.accent.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            ConverterOptionRow(label: "Remplacer") {
                HStack(spacing: 8) {
                    ConverterTextField(text: $model.options.rename.find, prompt: "ce texte…")
                    Text("par").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    ConverterTextField(text: $model.options.rename.replace, prompt: "(rien)")
                }
            }
            ConverterOptionRow(label: "Premier numéro") {
                ConverterStepper(value: $model.options.rename.start, range: 0...9999)
            }
            ConverterOptionRow(label: "Casse") {
                ConverterChips(options: ConverterCase.allCases, selection: $model.options.rename.caseMode) { $0.title }
            }
            ConverterOptionRow(label: "Extension") {
                ConverterChips(options: [false, true], selection: $model.options.rename.lowercaseExtension) { $0 ? "En minuscules" : "Inchangée" }
            }
        }
    }
}

/// The new names, before anything is renamed.
struct ConverterRenameList: View {
    let model: ConverterModel

    var body: some View {
        let preview = model.renamePreview
        let conflicts = preview.filter(\.conflict).count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("APERÇU").font(.ui(10, .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
                if conflicts > 0 {
                    Text("\(Fmt.plural(conflicts, "nom déjà pris", "noms déjà pris")) : un numéro sera ajouté").font(.ui(11)).foregroundStyle(Theme.warn)
                }
            }
            let rows = VStack(spacing: 1) {
                ForEach(preview.prefix(300)) { p in
                    HStack(spacing: 8) {
                        Text(p.url.lastPathComponent)
                            .font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.ui(9.5, .semibold)).foregroundStyle(p.unchanged ? Theme.text3 : Theme.accent)
                        HStack(spacing: 5) {
                            Text(p.newName)
                                .font(.ui(11.5, p.unchanged ? .regular : .medium))
                                .foregroundStyle(p.unchanged ? Theme.text3 : Theme.text)
                                .lineLimit(1).truncationMode(.middle)
                            if p.conflict { Image(systemName: "exclamationmark.triangle.fill").font(.ui(9.5)).foregroundStyle(Theme.warn) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            Group {
                if preview.count > 8 {
                    ScrollArea { rows }.frame(height: 200)
                } else {
                    rows
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(Theme.bg.opacity(0.5)))
        }
    }
}
