import AppKit
import CoreText
import SwiftUI

enum StrettoBrand {
    static let resources: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("StrettoNative_StrettoMac.bundle", isDirectory: true)) {
            return bundle
        }
        return Bundle.module
    }()

    static let blue = Color(red: 68 / 255, green: 187 / 255, blue: 1)
    static let readableBlue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.47, green: 0.81, blue: 1, alpha: 1)
            : NSColor(red: 0.03, green: 0.41, blue: 0.58, alpha: 1)
    })

    static let logoFont: String = {
        guard let url = resources.url(forResource: "wisdom", withExtension: "otf", subdirectory: "Resources") else {
            return NSFont.systemFont(ofSize: 32).fontName
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first,
           let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
            return name
        }
        return "WisdomScript"
    }()

    static var icon: NSImage? {
        guard let url = resources.url(forResource: "icon512", withExtension: "png", subdirectory: "Resources") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func registerFonts() { _ = logoFont }
}

struct StrettoLogo: View {
    var size: CGFloat = 36

    var body: some View {
        Text("stretto")
            .font(.custom(StrettoBrand.logoFont, size: size))
            .foregroundStyle(StrettoBrand.readableBlue)
            .accessibilityLabel("Stretto")
    }
}
