import AppKit
import CoreText
import SwiftUI

enum WidgetPalette {
    static let background = dynamic(0xF5F3ED, 0x1A1A1A)
    static let foreground = dynamic(0x1A1A1A, 0xF5F3ED)
    static let cellEmpty = dynamic(0xECEAE4, 0x2B2A27)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

enum WidgetFonts {
    private static var resources: Bundle {
        // `swift build` assumes its resource bundle sits at the app root.
        // Distributed macOS apps put it in Contents/Resources instead.
        if let url = Bundle.main.resourceURL?.appending(path: "InkletMac_InkletPresentationWidget.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }

    private static let registered: Void = {
        for name in ["Newsreader-Regular", "Inter-Regular"] {
            if let url = resources.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func brand(_ size: CGFloat) -> Font {
        _ = registered
        return .custom("Newsreader-Regular", size: size)
    }

    static func body(_ size: CGFloat) -> Font {
        _ = registered
        return .custom("Inter-Regular", size: size)
    }
}
