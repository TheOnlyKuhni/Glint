import AVFoundation

extension AVPlayerItem {
    /// macOS 27's player adds generated subtitles (a live transcript of the speech, with notes like "Typing") to
    /// any video it plays. In Glint's players the captions the user made are the only ones: the player draws no
    /// subtitles of its own. (They never reach an export; this is only the preview.)
    func hideSystemSubtitles() {
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        add(output)
        Task { [weak self] in
            guard let self, let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
            select(nil, in: group)
        }
    }
}

extension AVPlayer {
    /// A player that shows no subtitles of its own (see `AVPlayerItem.hideSystemSubtitles`).
    func hideSystemSubtitles() {
        appliesMediaSelectionCriteriaAutomatically = false
        currentItem?.hideSystemSubtitles()
    }
}
