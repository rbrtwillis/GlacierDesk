import AppKit
import SwiftUI

enum GlacierTheme {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    static let accent = adaptive(light: 0x006D91, dark: 0x54D5F3)
    static let background = adaptive(light: 0xF4F9FC, dark: 0x101D2C)
    static let sidebar = adaptive(light: 0xE8F2F7, dark: 0x142536)
}
