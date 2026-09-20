import AppKit
import SwiftUI
import TurnstileCore

@main
struct TurnstileBarApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        // No Dock icon, even when run outside the app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(monitor: monitor)
        } label: {
            let indicator = MenuBarState.indicator(monitor.snapshot)
            Image(nsImage: MenuBarIcon.image(indicator))
            if let count = indicator.count { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph. Monochrome like every other icon up there, until something wants attention.
enum MenuBarIcon {
    static func image(_ indicator: MenuBarState.Indicator) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: indicator.symbol, accessibilityDescription: "turnstile") else {
            return NSImage()
        }
        guard let colour = tint(indicator.tone) else {
            let image = symbol.withSymbolConfiguration(configuration) ?? symbol
            image.isTemplate = true
            return image
        }
        let coloured = symbol.withSymbolConfiguration(configuration.applying(.init(paletteColors: [colour]))) ?? symbol
        coloured.isTemplate = false
        return coloured
    }

    private static func tint(_ tone: MenuBarState.Tone) -> NSColor? {
        switch tone {
        case .danger: return .systemRed
        case .warning: return .systemOrange
        case .good, .neutral: return nil
        }
    }
}
