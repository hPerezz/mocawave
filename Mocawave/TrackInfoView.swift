import AppKit
import SwiftUI

/// Footer line under the waveform. The header says what is *measured in the file* (level, peak, real quality,
/// BPM, key); the footer says *what the track is* (genre, energy, year, label, and which sources say so), in the
/// same visual language as the header cells: icon + value, monospaced 10 pt semibold, a meter like LUFS/dB.
/// Click a source icon for a small dropdown with what it said (✓ = agrees with the consensus).
struct TrackInfoFooter: View {
    let state: TrackInfoState
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: MocaSpace.s) {
            switch state {
            case .idle:
                note("tag", "Genre and labels load once the track has played for a second")
            case .queued(let position):
                ProgressView().controlSize(.mini)
                note(nil, position > 1 ? "Analysing… \(position - 1) track(s) ahead" : "Analysing the track and asking the stores…")
            case .offline:
                note("bolt.horizontal.circle", "Track-info agent offline · run dj-stack/agent/run.sh")
                retry
            case .failed(let reason):
                note("exclamationmark.triangle", "No labels: \(reason)")
                retry
            case .ready(let info):
                ready(info)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .animation(MocaMotion.state, value: state)
    }

    @ViewBuilder
    private func ready(_ info: TrackInfo) -> some View {
        item("tag", genre(info), help: "genre · \(info.labels.genre?.source ?? "consensus")", emphasis: true)
        if let energy = info.labels.energy, case .number(let e) = energy.value {
            EnergyMeter(level: Int(e)).help("energy \(Int(e))/10 · \(energy.source)")
        }
        HStack(spacing: MocaSpace.xs) {
            ForEach(info.sources) { source in
                SourceIconButton(source: source,
                                 agrees: info.labels.style?.agree.contains(source.name) ?? false,
                                 beatportURL: source.name == "Beatport" ? info.labels.beatportUrl.flatMap(URL.init(string:)) : nil)
            }
        }
        Spacer(minLength: MocaSpace.s)
        if let copy = copyLine(info) {
            // Release credit, like the ℗ line on a record sleeve: year + label, quiet, right-aligned.
            Text(copy)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help([info.labels.year.map { "year · \($0.source)" }, info.labels.label.map { "label · \($0.source)" }]
                        .compactMap { $0 }.joined(separator: "\n"))
                .accessibilityLabel("Released \(copy.dropFirst(2))")
        }
    }

    /// "℗ 2017 Einmusika Recordings" (either part may be missing).
    private func copyLine(_ info: TrackInfo) -> String? {
        let parts = [info.labels.year?.value.description, info.labels.label?.value.description].compactMap { $0 }
        return parts.isEmpty ? nil : "℗ " + parts.joined(separator: " ")
    }

    /// Most specific genre a store gives (e.g. "Organic House"), else our consensus style.
    private func genre(_ info: TrackInfo) -> String {
        info.labels.genre?.value.description ?? info.labels.style?.value ?? "Unclear"
    }

    /// Icon + value, the same type as the header values (monospaced 10 pt semibold).
    private func item(_ icon: String, _ value: String, help: String, emphasis: Bool = false) -> some View {
        HStack(spacing: MocaSpace.xs) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(emphasis ? 0.95 : 0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(help.components(separatedBy: " · ").first.map { "\($0) \(value)" } ?? value)
    }

    private var retry: some View {
        Button("Retry", action: onRetry).buttonStyle(.borderless).font(.system(size: 10, weight: .semibold))
    }

    private func note(_ icon: String?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(.secondary)
    }
}

/// Energy 1–10 as ten tiny segments plus the number (colour is never the only signal).
private struct EnergyMeter: View {
    let level: Int

    var body: some View {
        HStack(spacing: 3) {
            Text("E\(level)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.9))
            HStack(spacing: 1.5) {
                ForEach(1...10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i <= level ? color(i) : Color.white.opacity(0.1))
                        .frame(width: 3, height: 8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("energy \(level) of 10")
    }

    private func color(_ i: Int) -> Color {
        i >= 8 ? MocaTheme.Cue.drop : (i >= 5 ? MocaTheme.Cue.build : MocaTheme.Cue.introOutro)
    }
}

// MARK: - Sources

/// Each source's mark: Apple = system Apple logo; Beatport = its official icon mark (vector); Deezer = its
/// official heart; ours = a waveform; file tag = a document.
private struct SourceIcon: View {
    let source: TrackInfo.Source

    var body: some View {
        Group {
            switch source.name {
            case "Apple Music":
                Image(systemName: "apple.logo").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.9))
            case "Beatport":
                BeatportMark().fill(Color(red: 0.0, green: 0.86, blue: 0.56)).frame(width: 11, height: 13)
            case "Deezer":
                if let heart = DeezerMark.image {
                    Image(nsImage: heart).resizable().interpolation(.high).frame(width: 13, height: 13)
                } else {
                    monogram("D", Color(red: 0.64, green: 0.22, blue: 1.0))
                }
            case "Our audio analysis":
                Image(systemName: "waveform").font(.system(size: 10, weight: .bold)).foregroundColor(MocaTheme.Cue.drop)
            default:
                Image(systemName: "doc.text").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func monogram(_ letter: String, _ color: Color) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundColor(.black.opacity(0.85))
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(color))
    }
}

/// Icon + agreement mark; click opens a compact dropdown with what the source said.
private struct SourceIconButton: View {
    let source: TrackInfo.Source
    let agrees: Bool
    let beatportURL: URL?

    @State private var open = false
    @State private var hovered = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 1) {
                SourceIcon(source: source)
                if source.genre != nil || source.style != nil {
                    Image(systemName: agrees ? "checkmark" : "minus")
                        .font(.system(size: 6, weight: .heavy))
                        .foregroundColor(agrees ? MocaTheme.color(for: .perfect) : .secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(hovered || open ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(source.name)
        .accessibilityLabel("\(source.name)\(agrees ? ", agrees" : "")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SourceDropdown(source: source, beatportURL: beatportURL)
        }
    }
}

/// Small fixed-width card: one line per field the source knows.
private struct SourceDropdown: View {
    let source: TrackInfo.Source
    let beatportURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: MocaSpace.xs) {
            HStack(spacing: 6) {
                SourceIcon(source: source)
                Text(source.name).font(.system(size: 11, weight: .bold))
            }
            .padding(.bottom, 2)
            ForEach(rows, id: \.0) { title, value in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(value).font(.system(size: 11, weight: .medium)).lineLimit(2)
                }
            }
            if let url = beatportURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open on Beatport", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .padding(MocaSpace.m)
        .frame(width: 240, alignment: .leading)
        .fixedSize()   // ideal size on both axes: the popover hugs its content
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = []
        func add(_ title: String, _ value: String?) { if let v = value, !v.isEmpty { out.append((title, v)) } }
        add("Genre", source.genre)
        add("Sub", source.subGenre)
        if source.kind == "audio" {
            add("Style", source.style)
            if let top = source.styles?.prefix(3), !top.isEmpty {
                add("Model", top.map { "\($0.label) \(Int(($0.p * 100).rounded()))%" }.joined(separator: ", "))
            }
            add("Energy", source.energy.map { "E\(Int($0))" })
            add("LUFS", source.lufs.map { String(format: "%.1f", $0) })
            add("Groove", source.groove)
        }
        add("Label", source.label)
        add("Year", source.year)
        add("Album", source.album)
        add("BPM", source.bpm.map { $0.rounded() == $0 ? "\(Int($0))" : String(format: "%.1f", $0) })
        add("Key", source.key)
        return out
    }
}
