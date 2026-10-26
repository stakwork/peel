import PeelCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// An app's icon, the Mac's and the iPhone's alike: the manifest's lucide
// name as the SF Symbol closest to it.

extension WorkspaceApp {
    /// Apps' icon, and an app's whose manifest names none Peel knows.
    static let symbol = "square.grid.2x2"

    /// Its icon: the manifest's lucide name as the SF Symbol closest to it,
    /// or Apps' grid for one not here or this system lacks.
    var iconSymbol: String {
        guard let icon, let symbol = Self.symbols[icon], Self.available.contains(symbol) else { return Self.symbol }
        return symbol
    }

    /// The table's symbols this system has, found once.
    private static let available = Set(symbols.values.filter {
        #if canImport(AppKit)
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        #else
        UIImage(systemName: $0) != nil
        #endif
    })

    /// The lucide names an app's manifest most often gives, as SF Symbols.
    /// `layout-dashboard`, the starter template's, stays the grid.
    private static let symbols: [String: String] = [
        "activity": "waveform.path.ecg", "alarm-clock": "alarm", "bar-chart": "chart.bar",
        "bar-chart-3": "chart.bar", "bell": "bell", "book": "book", "book-open": "book",
        "brain": "brain", "briefcase": "briefcase", "building": "building.2", "building-2": "building.2",
        "calendar": "calendar", "camera": "camera", "chart-bar": "chart.bar", "chart-column": "chart.bar",
        "chart-line": "chart.line.uptrend.xyaxis", "chart-pie": "chart.pie", "check-square": "checkmark.square",
        "circle-dollar-sign": "dollarsign.circle", "clock": "clock", "code": "chevron.left.forwardslash.chevron.right",
        "cpu": "cpu", "credit-card": "creditcard", "database": "cylinder.split.1x2", "dollar-sign": "dollarsign.circle",
        "eye": "eye", "file": "doc", "file-text": "doc.text", "flag": "flag", "flask-conical": "flask",
        "flask-round": "flask", "folder": "folder", "gauge": "gauge.with.dots.needle.33percent",
        "git-branch": "arrow.triangle.branch", "globe": "globe", "graduation-cap": "graduationcap",
        "heart": "heart", "home": "house", "house": "house", "image": "photo", "inbox": "tray",
        "kanban": "rectangle.split.3x1", "layers": "square.stack.3d.up", "lightbulb": "lightbulb",
        "line-chart": "chart.line.uptrend.xyaxis", "list": "list.bullet", "list-checks": "checklist",
        "list-todo": "checklist", "lock": "lock", "mail": "envelope", "map": "map", "map-pin": "mappin",
        "message-circle": "bubble.left", "message-square": "bubble.left", "music": "music.note",
        "network": "point.3.connected.trianglepath.dotted", "newspaper": "newspaper", "package": "shippingbox",
        "palette": "paintpalette", "pen": "pencil", "pencil": "pencil", "pie-chart": "chart.pie",
        "puzzle": "puzzlepiece", "receipt": "receipt", "scale": "scalemass", "search": "magnifyingglass",
        "server": "server.rack", "settings": "gearshape", "shield": "shield", "shield-check": "checkmark.shield",
        "shopping-cart": "cart", "sparkles": "sparkles", "square-check": "checkmark.square", "star": "star",
        "table": "tablecells", "tag": "tag", "target": "target", "terminal": "terminal",
        "test-tube": "testtube.2", "trending-up": "chart.line.uptrend.xyaxis", "trophy": "trophy",
        "truck": "truck.box", "user": "person", "users": "person.2", "utensils": "fork.knife",
        "wallet": "wallet.pass", "workflow": "point.3.connected.trianglepath.dotted", "zap": "bolt",
    ]
}
