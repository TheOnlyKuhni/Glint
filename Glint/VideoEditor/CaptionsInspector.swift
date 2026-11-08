import AVFoundation
import SwiftUI

private typealias W = VideoEditorWindowController

/// The video editor's Captions section: generate captions from the speech (or add them by hand), pick and adjust
/// their look, and edit the transcript.
struct CaptionsInspector: View {
    @ObservedObject var project: VideoProject
    @ObservedObject var state: VideoEditorState
    let actions: VideoEditorActions
    @StateObject private var generator = CaptionGenerator()
    @State private var language = CaptionGenerator.savedLanguage
    @State private var microphoneOnly = false
    @State private var audioTracks = 0

    private var style: Binding<CaptionStyle> { $project.edit.captionStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Captions", value: project.edit.captions.isEmpty ? nil : "\(project.edit.captions.count)")
            if project.edit.captions.isEmpty {
                generateSection
            } else {
                Toggle(isOn: $project.edit.showCaptions) { Text("Show captions").font(.system(size: 13.5)).foregroundStyle(.white) }
                    .toggleStyle(BlueSwitch())
                    .help("Show the captions in the video and the export")
                Group {
                    lookSection
                    transcriptSection
                }
                .opacity(project.edit.showCaptions ? 1 : 0.45)
                .disabled(!project.edit.showCaptions)
                regenerateSection
            }
        }
        .onChange(of: generator.languages) {
            // Not offered as such (e.g. a language with an unusual region): the closest one, same language first.
            guard !generator.languages.isEmpty, !generator.languages.contains(where: { $0.identifier == language }) else { return }
            let wanted = Locale(identifier: language)
            let sameLanguage = generator.languages.filter { $0.language.languageCode == wanted.language.languageCode }
            if let match = sameLanguage.first(where: { $0.region == wanted.region }) ?? sameLanguage.first { language = match.identifier }
        }
        .task {
            generator.loadLanguages()
            audioTracks = (try? await project.asset.loadTracks(withMediaType: .audio).count) ?? 0
        }
    }

    // MARK: Generate

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoBox {
                Text(project.hasAudio
                     ? "Glint turns what's said in the video into captions, here on your Mac. You can edit the text afterwards."
                     : "This video has no sound. You can still add captions by hand.")
            }
            if project.hasAudio { transcribeControls }
            addButton(title: "Add Caption by Hand")
        }
    }

    private var transcribeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Language").font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
                Spacer()
                Picker("", selection: $language) {
                    if !generator.languages.contains(where: { $0.identifier == language }) {
                        Text(CaptionGenerator.name(Locale(identifier: language))).tag(language)
                    }
                    ForEach(generator.languages, id: \.identifier) { Text(CaptionGenerator.name($0)).tag($0.identifier) }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                .onChange(of: language) { CaptionGenerator.savedLanguage = language }
                .help("The language spoken in the video")
            }
            if audioTracks > 1 {
                Toggle(isOn: $microphoneOnly) { Text("Microphone only").font(.system(size: 12.5)).foregroundStyle(.white) }
                    .toggleStyle(.checkbox)
                    .help("Transcribe only your voice, not sound from other apps (the recording kept them on separate tracks)")
            }
            switch generator.phase {
            case .idle:
                generateButton
            case .failed(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4)).fixedSize(horizontal: false, vertical: true)
                generateButton
            case .preparing, .transcribing:
                progressRow(generator.phase == .preparing ? "Preparing the audio…" : "Listening to the video…", value: nil)
            case .downloading(let p):
                progressRow("Downloading \(CaptionGenerator.name(Locale(identifier: language))) (once)…", value: p)
            }
            Text("macOS's own Live Captions (Accessibility) are a separate window: they're only in a video if they were on screen while recording.")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.45)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var generateButton: some View {
        Button {
            let firstTime = project.edit.captions.isEmpty
            generator.generate(project: project, language: language, microphoneOnly: microphoneOnly) { captions in
                var next = project.edit
                next.captions = captions
                if firstTime { next.captionStyle = .standard; next.showCaptions = true }
                project.edit = next
            }
        } label: {
            Label(project.edit.captions.isEmpty ? "Generate Captions" : "Generate Again", systemImage: "captions.bubble")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(W.blue))
        }
        .buttonStyle(HoverButtonStyle())
        .help("Transcribe the speech into timed captions")
    }

    private func progressRow(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12.5)).foregroundStyle(.white)
                Spacer()
                Button("Cancel") { generator.cancel() }.buttonStyle(.link).font(.system(size: 12))
            }
            if let value { ProgressView(value: value) } else { ProgressView().progressViewStyle(.linear) }
        }
    }

    private func addButton(title: String) -> some View {
        Button {
            let t = project.locate(state.time)?.source ?? 0
            var next = project.edit
            if next.captions.isEmpty { next.captionStyle = .standard; next.showCaptions = true }
            let caption = Caption(words: Caption.spread(["New", "caption"], from: t, to: min(t + 2, project.sourceDuration)))
            next.captions.append(caption)
            next.captions.sort { $0.start < $1.start }
            project.edit = next
            state.selectedCaption = caption.id
        } label: {
            Label(title, systemImage: "plus").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box))
        }
        .buttonStyle(HoverButtonStyle())
        .help("A two-second caption at the playhead")
    }

    // MARK: Look

    private var lookSection: some View {
        let s = project.edit.captionStyle
        return VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Style").padding(.top, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(CaptionPreset.allCases, id: \.self) { preset in
                    Button {
                        // A preset replaces the look but keeps where the captions are.
                        var next = CaptionStyle.preset(preset)
                        if preset != .social { next.position = s.position; next.offset = s.offset }
                        style.wrappedValue = next
                    } label: {
                        PresetSample(preset: preset, selected: s.preset == preset)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help(preset.help)
                }
            }
            InspectorHeader("Show").padding(.top, 8)
            ChoiceButtons(titles: CaptionMode.allCases.map(\.title), selected: s.mode == .phrases ? 0 : 1,
                          helps: ["Whole phrases, up to two lines (more formal)", "A few words at a time, each appearing as it's said"]) {
                style.wrappedValue.mode = $0 == 0 ? .phrases : .words
            }
            if s.mode == .words {
                InspectorHeader("Words at once", value: "\(s.wordsPerChunk)").padding(.top, 4)
                StepSlider(value: Binding(get: { Double(s.wordsPerChunk) }, set: { style.wrappedValue.wordsPerChunk = Int($0.rounded()) }),
                           range: 1...5, step: 1, ticks: 5)
                InspectorHeader("Animation").padding(.top, 4)
                ChoiceButtons(titles: CaptionAnimation.allCases.map(\.title), selected: CaptionAnimation.allCases.firstIndex(of: s.animation) ?? 0,
                              helps: ["Words just appear", "Words pop in with a little bounce", "Words fade in"]) {
                    style.wrappedValue.animation = CaptionAnimation.allCases[$0]
                }
            } else {
                InspectorHeader("Line length", value: "\(s.lineLength) characters").padding(.top, 4)
                StepSlider(value: Binding(get: { Double(s.lineLength) }, set: { style.wrappedValue.lineLength = Int($0.rounded()) }),
                           range: 20...60, step: 2, ticks: 5)
            }
            Toggle(isOn: style.highlightWord) {
                Text(s.mode == .phrases ? "Highlight the spoken word" : "Highlight the newest word").font(.system(size: 12.5)).foregroundStyle(.white)
            }
            .toggleStyle(.checkbox)

            InspectorHeader("Text").padding(.top, 8)
            HStack {
                Picker("", selection: style.font) { ForEach(CaptionFont.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: 130)
                Spacer()
                ColorWell(hex: style.textColor, help: "Text color")
                ColorWell(hex: style.highlightColor, help: "Highlight color")
            }
            InspectorHeader("Size", percent: Binding(get: { s.size }, set: { style.wrappedValue.size = $0 }), range: 0.5...2.5).padding(.top, 4)
            StepSlider(value: style.size, range: 0.5...2.5, ticks: 5)
            HStack(spacing: 14) {
                Toggle(isOn: style.bold) { Text("Bold").font(.system(size: 12.5)).foregroundStyle(.white) }
                Toggle(isOn: style.uppercase) { Text("Capitals").font(.system(size: 12.5)).foregroundStyle(.white) }
                Toggle(isOn: style.outline) { Text("Outline").font(.system(size: 12.5)).foregroundStyle(.white) }
            }
            .toggleStyle(.checkbox)

            HStack {
                Toggle(isOn: style.box) { Text("Box").font(.system(size: 13.5)).foregroundStyle(.white) }.toggleStyle(BlueSwitch())
                Spacer()
                if s.box { ColorWell(hex: style.boxColor, help: "Box color") }
            }
            .padding(.top, 8)
            if s.box {
                InspectorHeader("Box opacity", percent: style.boxOpacity, range: 0...1)
                StepSlider(value: style.boxOpacity, range: 0...1, ticks: 5)
            }

            InspectorHeader("Position").padding(.top, 8)
            ChoiceButtons(titles: CaptionPosition.allCases.map(\.title), selected: CaptionPosition.allCases.firstIndex(of: s.position) ?? 2) {
                style.wrappedValue.position = CaptionPosition.allCases[$0]
                style.wrappedValue.offset = 0
            }
            InspectorHeader("Move up or down", percent: style.offset, range: -0.45...0.45).padding(.top, 4)
            StepSlider(value: style.offset, range: -0.45...0.45, ticks: 3)
                .help("Fine placement from the chosen position")
        }
    }

    // MARK: Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorHeader("Transcript").padding(.top, 12)
            Text("Click a time to jump there. Edit the text; Split breaks a caption where the text cursor is.")
                .font(.system(size: 11.5)).foregroundStyle(Color(white: 0.5)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(project.edit.captions.enumerated()), id: \.element.id) { i, caption in
                if i > 0 { mergeLink(i - 1) }
                CaptionRow(caption: caption, project: project, state: state, actions: actions)
            }
            addButton(title: "Add Caption at the Playhead")
        }
    }

    /// Between two captions: joins them into one.
    private func mergeLink(_ i: Int) -> some View {
        Button {
            guard i + 1 < project.edit.captions.count else { return }
            var next = project.edit
            next.captions[i].words += next.captions[i + 1].words
            next.captions[i].matched = nil
            next.captions.remove(at: i + 1)
            project.edit = next
        } label: {
            Image(systemName: "link").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(white: 0.6))
                .frame(width: 26, height: 16)
                .background(Capsule().fill(W.box))
        }
        .buttonStyle(HoverButtonStyle())
        .frame(maxWidth: .infinity)
        .padding(.vertical, -4)
        .help("Merge these two captions")
    }

    private var regenerateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if project.hasAudio {
                InspectorHeader("Transcribe again").padding(.top, 12)
                transcribeControls
            }
            Button(role: .destructive) {
                project.edit.captions = []
            } label: {
                Text("Remove All Captions").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box))
            }
            .buttonStyle(HoverButtonStyle())
            .help("Delete every caption (⌘Z brings them back)")
        }
    }
}

/// One caption in the transcript: its time (click to jump there), its text, and Split / Merge / Delete.
private struct CaptionRow: View {
    let caption: Caption
    @ObservedObject var project: VideoProject
    @ObservedObject var state: VideoEditorState
    let actions: VideoEditorActions
    @State private var text = ""
    @State private var selection: TextSelection?
    /// Where the text cursor last was (clicking Split takes the focus, and the selection, away).
    @State private var cursor: Int?
    @FocusState private var focused: Bool

    private var index: Int? { project.edit.captions.firstIndex { $0.id == caption.id } }
    private var output: Double? { project.outputTime(source: caption.start) }
    private var isCurrent: Bool {
        guard let start = output else { return false }
        let end = project.outputTime(source: caption.end) ?? start
        return state.time >= start && state.time < end + 0.25
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if let output { actions.seek(output) }
                    state.selectedCaption = caption.id
                } label: {
                    Text(output.map(Self.stamp) ?? "cut out").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(output == nil ? Color(white: 0.4) : W.blue)
                }
                .buttonStyle(.plain)
                .help("Jump to this caption")
                Spacer()
                icon("scissors", "Split this caption where the text cursor is") { split() }
                icon("trash", "Delete this caption") { delete() }
            }
            TextField("", text: $text, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
                .onChange(of: selection) {
                    if case .selection(let range)? = selection?.indices { cursor = text.distance(from: text.startIndex, to: range.lowerBound) }
                }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(W.box))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(state.selectedCaption == caption.id ? W.blue : (isCurrent ? Color.white.opacity(0.35) : .clear), lineWidth: 1.5))
        .contextMenu {
            Button("Back to Where It Was Said") { resetTiming() }.disabled(caption.matched == nil)
            Button("Delete Caption") { delete() }
        }
        .onAppear { text = caption.text }
        .onChange(of: caption.text) { if !focused { text = caption.text } }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(white: 0.7)).frame(width: 22, height: 20)
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }

    private func commit() {
        guard let i = index, text != project.edit.captions[i].text else { return }
        var next = project.edit
        next.captions[i].setText(text)
        if next.captions[i].words.isEmpty { next.captions.remove(at: i) }
        project.edit = next
    }

    /// Splits at the word the text cursor is in front of (the words keep their times).
    private func split() {
        commit()
        guard let i = index else { return }
        let at = text.index(text.startIndex, offsetBy: min(cursor ?? text.count, text.count))
        let before = text[..<at].split(whereSeparator: \.isWhitespace).count
        let words = project.edit.captions[i].words
        guard before > 0, before < words.count else { NSSound.beep(); return }
        var next = project.edit
        next.captions[i].words = Array(words[..<before])
        next.captions[i].matched = nil
        next.captions.insert(Caption(words: Array(words[before...])), at: i + 1)
        project.edit = next
        // The field still shows the whole text: it would put the moved words back when it loses the focus.
        text = next.captions[i].text
        cursor = nil
    }

    private func resetTiming() {
        guard let i = index, let m = caption.matched, m.count == 2 else { return }
        project.edit.captions[i].retime(start: m[0], end: m[1])
    }

    private func delete() {
        guard let i = index else { return }
        project.edit.captions.remove(at: i)
    }

    static func stamp(_ t: Double) -> String {
        let tenths = Int((t * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// A preset's tile: "Aa" in its look on a dark sample.
private struct PresetSample: View {
    let preset: CaptionPreset
    let selected: Bool

    var body: some View {
        let s = CaptionStyle.preset(preset)
        VStack(spacing: 4) {
            Text(s.uppercase ? "AA" : "Aa")
                .font(.system(size: 14, weight: s.bold ? .heavy : .semibold))
                .foregroundStyle(Color(nsColor: CaptionRenderer.color(s.textColor)))
                .shadow(color: s.outline ? .black : .clear, radius: 0, x: 1, y: 1)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(s.box ? Color(nsColor: CaptionRenderer.color(s.boxColor)).opacity(s.boxOpacity) : .clear))
            Text(preset.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity).frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.3)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? W.blue : .clear, lineWidth: 2))
    }
}

/// A small color well for a Display P3 hex value.
private struct ColorWell: View {
    @Binding var hex: UInt32
    let help: String

    var body: some View {
        ColorPicker("", selection: Binding(get: { Color(nsColor: AnnotationColor(hex: hex).nsColor) },
                                           set: { hex = AnnotationColor(NSColor($0)).hex }), supportsOpacity: false)
            .labelsHidden()
            .help(help)
    }
}
