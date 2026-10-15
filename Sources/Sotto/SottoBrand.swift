import AppKit

enum SottoBrand {
    static let appImage: NSImage = {
        Bundle.main.url(forResource: "SottoIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sotto")!
    }()
    static let menuImage: NSImage = {
        let image = Bundle.main.url(forResource: "SottoMenuTemplate", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sotto")!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
