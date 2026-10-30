import SwiftUI

struct RecordingSettingsView: View {
    @AppStorage(Prefs.recShowControls) private var showControls
    @AppStorage(Prefs.recRememberSelection) private var rememberSelection
    @AppStorage(Prefs.recTimeInMenuBar) private var timeInMenuBar
    @AppStorage(Prefs.recDimScreen) private var dimScreen
    @AppStorage(Prefs.recCountdown) private var countdown
    @AppStorage(Prefs.recDoNotDisturb) private var doNotDisturb
    @AppStorage(Prefs.recShowCursor) private var showCursor
    @AppStorage(Prefs.recHighlightClicks) private var highlightClicks
    @AppStorage(Prefs.recShowKeystrokes) private var showKeystrokes
    @AppStorage(Prefs.recFrameRate) private var frameRate
    @AppStorage(Prefs.recMaxResolution) private var maxResolution
    @AppStorage(Prefs.recScaleTo1x) private var scaleTo1x
    @AppStorage(Prefs.recMono) private var mono
    @AppStorage(Prefs.recSystemAudio) private var systemAudio
    @AppStorage(Prefs.recAudioTracks) private var audioTracks
    @AppStorage(Prefs.gifFrameRate) private var gifFrameRate
    @AppStorage(Prefs.gifResolution) private var gifResolution
    @AppStorage(Prefs.gifOptimize) private var gifOptimize
    @AppStorage(Prefs.gifQuality) private var gifQuality
    /// Shown in the recorder's settings popover: switches, with Options… left of them.
    var compact = false
    @State private var showClickOptions = false
    @State private var showKeyOptions = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show controls while recording", isOn: $showControls)
                Toggle("Remember last selection", isOn: $rememberSelection)
                Toggle("Display recording time in menu bar", isOn: $timeInMenuBar)
                Toggle("Dim screen while recording", isOn: $dimScreen)
                Toggle("Show countdown", isOn: $countdown)
                Toggle(isOn: $doNotDisturb) {
                    Text("\"Do Not Disturb\" while recording")
                    Text("Glint adds two shortcuts to the Shortcuts app for this (macOS has no other way).")
                }
                .onChange(of: doNotDisturb) { _, on in
                    guard on else { return }
                    Task { if await !DoNotDisturb.isSetUp() { DoNotDisturb.offerSetup() } }
                }
            }
            Section("Cursor") {
                Toggle("Show cursor", isOn: $showCursor)
                LabeledContent("Highlight clicks") {
                    HStack {
                        Button("Options…") { showClickOptions = true }
                            .popover(isPresented: $showClickOptions, arrowEdge: .bottom) { ClickOptionsView().frame(width: 300) }
                        Toggle("Highlight clicks", isOn: $highlightClicks).labelsHidden()
                    }
                }
            }
            Section("Keystrokes") {
                LabeledContent("Show keystrokes") {
                    HStack {
                        Button("Options…") { showKeyOptions = true }
                            .popover(isPresented: $showKeyOptions, arrowEdge: .bottom) { KeystrokeOptionsView().frame(width: 320) }
                        Toggle("Show keystrokes", isOn: Binding(get: { showKeystrokes },
                                                               set: { if !$0 || KeystrokePermission.ensure() { showKeystrokes = $0 } }))
                            .labelsHidden()
                    }
                }
            }
            Section("Video") {
                Picker("Frame rate", selection: $frameRate) {
                    ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker(selection: $maxResolution) {
                    ForEach(MaxResolution.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Max resolution")
                    Text("Set maximum resolution to reduce file size.")
                }
                Toggle("Scale Retina videos to 1x", isOn: $scaleTo1x)
            }
            Section("Audio") {
                Toggle("Record audio in mono", isOn: $mono)
                Toggle(isOn: $systemAudio) {
                    Text("Record system audio")
                    Text("Enable this option to record sound that comes from other applications.")
                }
                Picker(selection: $audioTracks) {
                    ForEach(AudioTracks.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Audio tracks")
                    Text("Choose separate tracks to edit the microphone and system audio independently in video editing software.")
                }
            }
            Section("GIF") {
                Picker("Frame rate", selection: $gifFrameRate) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Resolution", selection: $gifResolution) {
                    ForEach([480, 640, 800, 1024], id: \.self) { Text($0 == 800 ? "800 x auto (default)" : "\($0) x auto").tag($0) }
                }
                Toggle("Optimize GIFs", isOn: $gifOptimize)
                LabeledContent("Quality") {
                    HStack {
                        Text("Low").foregroundStyle(.secondary)
                        Slider(value: $gifQuality, in: 0...1).frame(width: 160)
                        Text("High").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(compact ? .hidden : .automatic)
    }
}

struct AnnotateSettingsView: View {
    @AppStorage(Prefs.annotateInverseArrow) private var inverseArrow
    @AppStorage(Prefs.annotateSmoothDrawing) private var smoothDrawing
    @AppStorage(Prefs.annotateRememberBackground) private var rememberBackground
    @AppStorage(Prefs.annotateShadow) private var shadow
    @AppStorage(Prefs.annotateExpandCanvas) private var expandCanvas
    @AppStorage(Prefs.annotateAlwaysOnTop) private var alwaysOnTop
    @AppStorage(Prefs.annotateShowDockIcon) private var showDockIcon
    @AppStorage(Prefs.annotateColorNames) private var colorNames

    var body: some View {
        Form {
            Section("Tools") {
                Toggle(isOn: $inverseArrow) {
                    Text("Inverse arrow direction")
                    Text("Press ⌥ (option) when drawing to invert the behavior.")
                }
                Toggle("Smooth drawing", isOn: $smoothDrawing)
                Toggle("Remember if background tool was opened", isOn: $rememberBackground)
                Toggle("Draw shadow on objects", isOn: $shadow)
                Toggle(isOn: $expandCanvas) {
                    Text("Grow canvas to fit annotations")
                    Text("Annotations past the edge widen the canvas on every side, so the screenshot stays centered. Off: they're cut off at the screenshot's edge. Also in the editor's bottom bar.")
                }
            }
            Section("Window") {
                Toggle("Always on top", isOn: $alwaysOnTop)
                Toggle("Show Dock icon", isOn: $showDockIcon)
            }
            Section("Accessibility") {
                Toggle("Show color names", isOn: $colorNames)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettingsView: View {
    @AppStorage(Prefs.askForName) private var askForName
    @AppStorage(Prefs.fileNameFormat) private var fileNameFormat
    @AppStorage(Prefs.add2xSuffix) private var add2xSuffix
    @AppStorage(Prefs.clipboardMode) private var clipboardMode
    @AppStorage(Prefs.historyDays) private var historyDays
    @AppStorage(Prefs.ocrKeepLineBreaks) private var keepLineBreaks
    @AppStorage(Prefs.ocrDetectLinks) private var detectLinks
    @AppStorage(Prefs.ocrKeepLists) private var keepLists
    @AppStorage(Prefs.ocrCopyTextWithQR) private var copyTextWithQR
    @AppStorage(Prefs.ocrLanguage) private var ocrLanguage
    @AppStorage(Prefs.allInOneRememberSelection) private var allInOneRemember
    @AppStorage(Prefs.pinRoundedCorners) private var pinRounded
    @AppStorage(Prefs.pinShadow) private var pinShadow
    @AppStorage(Prefs.pinBorder) private var pinBorder
    @AppStorage(Prefs.allowURLScheme) private var allowURLScheme
    @State private var editingFormat = false

    var body: some View {
        Form {
            Section("File Name") {
                Toggle("Ask for name after every capture", isOn: $askForName)
                LabeledContent("File name format") {
                    Button("Customize…") { editingFormat = true }
                }
                Toggle(isOn: $add2xSuffix) {
                    Text("Add \"@2x\" suffix to Retina screenshots")
                    Text("This option improves compatibility with displaying Retina screenshots in third-party apps.")
                }
            }
            Section("Clipboard") {
                Picker(selection: $clipboardMode) {
                    ForEach(ClipboardMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Copy to clipboard")
                    Text("Adjust this option if you've encountered any issues with pasting from clipboard or clipboard managers.")
                }
            }
            Section("Capture History") {
                Picker(selection: $historyDays) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                    Text("Forever").tag(0)
                } label: {
                    Text("Keep history")
                    Text("You can restore old files with \"Capture History\" option from the menu bar.")
                }
            }
            Section("Text Recognition") {
                Picker("Language", selection: $ocrLanguage) {
                    Text("Automatically Detect Language").tag("auto")
                    Divider()
                    ForEach(TextRecognizer.supportedLanguages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Toggle("Keep line breaks", isOn: $keepLineBreaks)
                Toggle(isOn: $keepLists) {
                    Text("Keep list formatting")
                    Text("Bullets become \"-\", numbering like \"1.\" stays, indented lines stay indented.")
                }
                .disabled(!keepLineBreaks)
                Toggle(isOn: $detectLinks) {
                    Text("Detect links")
                    Text("When the recognized text contains a link, the notification offers to open it.")
                }
                Toggle(isOn: $copyTextWithQR) {
                    Text("Copy text together with QR codes")
                    Text("Capture Text also reads QR codes and barcodes. Off: only the code's content is copied.")
                }
            }
            Section("All-In-One") {
                Toggle("Remember last selection", isOn: $allInOneRemember)
            }
            Section("Pinned Screenshots") {
                Toggle("Rounded corners", isOn: $pinRounded)
                Toggle("Shadow", isOn: $pinShadow)
                Toggle("Border", isOn: $pinBorder)
            }
            Section("API") {
                Toggle(isOn: $allowURLScheme) {
                    Text("Allow URL scheme API")
                    Text("Disable this option to prevent external apps from controlling Glint via URL scheme API.")
                }
            }
            Section("Uninstall") {
                LabeledContent {
                    Button("Uninstall Glint…") { Uninstaller.confirmAndRun() }
                } label: {
                    Text("Remove Glint from this Mac")
                    Text("Deletes Glint's settings, history and logs, resets its permissions and moves the app to the Trash. Your saved captures stay.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingFormat) { FileNameFormatSheet(format: $fileNameFormat) }
    }
}

private struct FileNameFormatSheet: View {
    @Binding var format: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Name Format").font(.headline)
            TextField("Format", text: $format).textFieldStyle(.roundedBorder)
            Text("Placeholders: {yyyy} {MM} {dd} {HH} {mm} {ss}").font(.callout).foregroundStyle(.secondary)
            Text("Preview: \(FileNaming.name(for: Date(), template: format)).png").font(.callout)
            HStack {
                Button("Reset") { format = Prefs.fileNameFormat.defaultValue }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct AboutSettingsView: View {
    // About pane: icon, name, version, copyright, then a list of links.
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                    Text("Glint").font(.system(size: 26, weight: .semibold))
                    Text("\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))").foregroundStyle(.secondary)
                    Text("Screenshots, recordings and annotations for macOS.").font(.callout).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            Section("Links") {
                link("photo.on.rectangle.angled", "Capture History") { CaptureHistory.shared.show() }
                link("folder", "Captures Folder") { NSWorkspace.shared.open(HistoryStore.shared.directory) }
                link("square.and.arrow.down", "Export Location") { NSWorkspace.shared.open(FileSaver.exportDirectory) }
            }
            Section("Glint") {
                link("chevron.left.forwardslash.chevron.right", "Source Code on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/TheOnlyKuhni/Glint")!)
                }
                link("cup.and.saucer", "Support Glint on Ko-fi") {
                    NSWorkspace.shared.open(URL(string: "https://ko-fi.com/kuhni")!)
                }
                link("doc.text", "Acknowledgements") {
                    if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func link(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Highlight clicks: color, size and ring or filled circle.
struct ClickOptionsView: View {
    @AppStorage(Prefs.recClickColor) private var colorHex
    @AppStorage(Prefs.recClickSize) private var size
    @AppStorage(Prefs.recClickFilled) private var filled

    var body: some View {
        Form {
            ColorPicker("Color", selection: Binding(get: { Color(nsColor: NSColor(hex: colorHex) ?? .systemBlue) },
                                                    set: { colorHex = NSColor($0).hexString }), supportsOpacity: false)
            Picker("Style", selection: $filled) {
                Text("Ring").tag(false)
                Text("Filled").tag(true)
            }
            .pickerStyle(.segmented)
            LabeledContent("Size") { Slider(value: $size, in: 0.6...1.8) }
        }
        .formStyle(.grouped)
    }
}

/// Show keystrokes: where, how big, how long, and whether plain typing shows too.
struct KeystrokeOptionsView: View {
    @AppStorage(Prefs.recKeysPosition) private var position
    @AppStorage(Prefs.recKeysSize) private var size
    @AppStorage(Prefs.recKeysDuration) private var duration
    @AppStorage(Prefs.recKeysShortcutsOnly) private var shortcutsOnly

    var body: some View {
        Form {
            Picker("Position", selection: $position) {
                Text("Bottom").tag("bottom")
                Text("Top").tag("top")
            }
            .pickerStyle(.segmented)
            Picker("Size", selection: $size) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
            }
            .pickerStyle(.segmented)
            LabeledContent("Display time") {
                HStack { Slider(value: $duration, in: 0.5...4, step: 0.5); Text(String(format: "%.1f s", duration)).monospacedDigit() }
            }
            Toggle("Only shortcuts (keys with ⌘ ⌥ ⌃)", isOn: $shortcutsOnly)
        }
        .formStyle(.grouped)
    }
}
