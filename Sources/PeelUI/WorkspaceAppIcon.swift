import LucideSwift
import PeelCore
import SwiftUI

// An app's icon, the Mac's and the iPhone's alike: the manifest's `icon` is a
// kebab-case lucide name (strut's own library), drawn as that icon. Any name
// lucide has works, its older aliases too; a name it has not, or none, is the
// Apps grid. The apps use `WorkspaceAppIcon`; they never import LucideSwift.

/// Which lucide icon a manifest's name is.
public enum LucideNames {
    /// The icon drawn for no name, or one lucide has not: Apps' grid, four squares.
    public static let fallback = "layout-grid"

    /// The package's name for the icon `name` is, as a manifest writes it:
    /// itself, or what a renamed icon is now (`home` is `house`); nil for one
    /// lucide has not. Its spelling is the package's (`arrowRight`, and
    /// `repeatIcon` for a Swift keyword), good for nothing but `LucideIconName`.
    public static func resolve(_ name: String?) -> String? {
        guard let written = name?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if let found = index[key(written)] { return found }
        return aliases[written].flatMap { index[key($0)] }
    }

    /// The icon's shape for a manifest's name: its own, or the grid's.
    static func shape(of name: String?) -> LucideShape {
        resolve(name).flatMap { LucideIconName(rawValue: $0) }?.shape ?? Lucide.layoutGrid
    }

    /// Letters and digits only, lower case: `arrow-right` and `arrowRight` meet here.
    private static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) })
    }

    /// The package's name for each key.
    private static let index: [String: String] = {
        var index: [String: String] = [:]
        for icon in LucideIconName.allCases { index[key(icon.rawValue)] = icon.rawValue }
        // A Swift keyword's case ends in "Icon" (`repeat`, `package`): the keyword finds it.
        for (key, raw) in index where raw.hasSuffix("Icon") && index[String(key.dropLast(4))] == nil {
            index[String(key.dropLast(4))] = raw
        }
        return index
    }()

    /// The names lucide still takes for an icon it renamed (its `aliases`),
    /// each as the name it has now. The package has the current names alone.
    private static let aliases: [String: String] = [
        "activity-square": "square-activity", "alarm-check": "alarm-clock-check", "alarm-minus": "alarm-clock-minus",
        "alarm-plus": "alarm-clock-plus", "album": "square-bookmark", "alert-circle": "circle-alert",
        "alert-octagon": "octagon-alert", "alert-triangle": "triangle-alert", "align-center": "text-align-center",
        "align-justify": "text-align-justify", "align-left": "text-align-start", "align-right": "text-align-end",
        "angry": "face-angry", "annoyed": "face-expressionless", "archive-restore": "archive-arrow-up",
        "area-chart": "chart-area", "arrow-down-circle": "circle-arrow-down",
        "arrow-down-left-from-circle": "circle-arrow-out-down-left",
        "arrow-down-left-from-square": "square-arrow-out-down-left",
        "arrow-down-left-square": "square-arrow-down-left",
        "arrow-down-right-from-circle": "circle-arrow-out-down-right",
        "arrow-down-right-from-square": "square-arrow-out-down-right",
        "arrow-down-right-square": "square-arrow-down-right", "arrow-down-square": "square-arrow-down",
        "arrow-left-circle": "circle-arrow-left", "arrow-left-square": "square-arrow-left",
        "arrow-right-circle": "circle-arrow-right", "arrow-right-square": "square-arrow-right",
        "arrow-up-circle": "circle-arrow-up", "arrow-up-left-from-circle": "circle-arrow-out-up-left",
        "arrow-up-left-from-square": "square-arrow-out-up-left", "arrow-up-left-square": "square-arrow-up-left",
        "arrow-up-right-from-circle": "circle-arrow-out-up-right",
        "arrow-up-right-from-square": "square-arrow-out-up-right", "arrow-up-right-square": "square-arrow-up-right",
        "arrow-up-square": "square-arrow-up", "asterisk-square": "square-asterisk",
        "badge-help": "badge-question-mark", "bar-chart": "chart-no-axes-column-increasing",
        "bar-chart-2": "chart-no-axes-column", "bar-chart-3": "chart-column",
        "bar-chart-4": "chart-column-increasing", "bar-chart-big": "chart-column-big",
        "bar-chart-horizontal": "chart-bar", "bar-chart-horizontal-big": "chart-bar-big",
        "between-horizonal-end": "between-horizontal-end", "between-horizonal-start": "between-horizontal-start",
        "book-marked": "book-bookmark", "book-template": "book-dashed", "box-select": "square-dashed",
        "building-2": "building-complex", "candlestick-chart": "chart-candlestick",
        "check-circle": "circle-check-big", "check-circle-2": "circle-check", "check-square": "square-check-big",
        "check-square-2": "square-check", "chevron-down-circle": "circle-chevron-down",
        "chevron-down-square": "square-chevron-down", "chevron-left-circle": "circle-chevron-left",
        "chevron-left-square": "square-chevron-left", "chevron-right-circle": "circle-chevron-right",
        "chevron-right-square": "square-chevron-right", "chevron-up-circle": "circle-chevron-up",
        "chevron-up-square": "square-chevron-up", "circle-help": "circle-question-mark",
        "circle-slashed": "circle-slash-2", "clipboard-edit": "clipboard-pen",
        "clipboard-signature": "clipboard-pen-line", "code-2": "code-xml", "code-square": "square-code",
        "columns": "columns-2", "columns-settings": "columns-3-cog", "contact-2": "contact-round",
        "curly-braces": "braces", "divide-circle": "circle-divide", "divide-square": "square-divide",
        "dot-square": "square-dot", "download-cloud": "cloud-download", "edit": "square-pen", "edit-2": "pen",
        "edit-3": "pen-line", "equal-square": "square-equal", "file-audio": "file-headphone",
        "file-audio-2": "file-headphone", "file-badge-2": "file-badge",
        "file-bar-chart": "file-chart-column-increasing", "file-bar-chart-2": "file-chart-column",
        "file-check-2": "file-check-corner", "file-code-2": "file-code-corner", "file-cog-2": "file-cog",
        "file-edit": "file-pen", "file-json": "file-braces", "file-json-2": "file-braces-corner",
        "file-key-2": "file-key", "file-line-chart": "file-chart-line", "file-lock-2": "file-lock",
        "file-minus-2": "file-minus-corner", "file-pie-chart": "file-chart-pie", "file-plus-2": "file-plus-corner",
        "file-question": "file-question-mark", "file-search-2": "file-search-corner",
        "file-signature": "file-pen-line", "file-type-2": "file-type-corner", "file-video": "file-play",
        "file-video-2": "file-video-camera", "file-volume-2": "file-signal",
        "file-warning": "file-exclamation-point", "file-x-2": "file-x-corner", "filter": "funnel",
        "filter-x": "funnel-x", "fingerprint": "fingerprint-pattern",
        "flip-horizontal": "square-centerline-dashed-horizontal",
        "flip-horizontal-2": "triangles-centerline-dashed-horizontal",
        "flip-vertical": "square-centerline-dashed-vertical",
        "flip-vertical-2": "triangles-centerline-dashed-vertical", "folder-cog-2": "folder-cog",
        "folder-edit": "folder-pen", "fork-knife": "utensils", "fork-knife-crossed": "utensils-crossed",
        "form-input": "rectangle-ellipsis", "frown": "face-slightly-frowning", "function-square": "square-function",
        "gantt-chart": "chart-no-axes-gantt", "gantt-chart-square": "square-chart-gantt",
        "gauge-circle": "circle-gauge", "git-commit": "git-commit-horizontal", "globe-2": "earth",
        "grab": "hand-grab", "grid": "grid-3-x-3", "help-circle": "circle-question-mark",
        "helping-hand": "hand-helping", "history": "rotate-ccw-clock", "home": "house",
        "ice-cream": "ice-cream-cone", "ice-cream-2": "ice-cream-bowl", "indent": "list-indent-increase",
        "indent-decrease": "list-indent-decrease", "indent-increase": "list-indent-increase",
        "inspect": "square-mouse-pointer", "kanban-square": "square-kanban",
        "kanban-square-dashed": "square-dashed-kanban", "laptop-2": "laptop-minimal", "laugh": "face-grinning",
        "layers-3": "layers", "layout": "panels-top-left", "letter-text": "text-initial",
        "library-square": "square-library", "line-chart": "chart-line", "loader-2": "loader-circle",
        "location-edit": "map-pin-pen", "m-square": "square-m", "mail-question": "mail-question-mark",
        "meh": "face-neutral", "menu-square": "square-menu",
        "message-circle-question": "message-circle-question-mark", "mic-2": "mic-vocal",
        "minus-circle": "circle-minus", "minus-square": "square-minus", "more-horizontal": "ellipsis",
        "more-vertical": "ellipsis-vertical", "mouse-pointer-square-dashed": "square-dashed-mouse-pointer",
        "music": "eighth-notes", "music-2": "eighth-note", "music-3": "half-note", "music-4": "sixteenth-notes",
        "outdent": "list-indent-decrease", "paintbrush-2": "paintbrush-vertical", "palmtree": "tree-palm",
        "panel-bottom-inactive": "panel-bottom-dashed", "panel-left-inactive": "panel-left-dashed",
        "panel-right-inactive": "panel-right-dashed", "panel-top-inactive": "panel-top-dashed",
        "panels-left-right": "columns-3", "panels-top-bottom": "rows-3", "parking-circle": "circle-parking",
        "parking-circle-off": "circle-parking-off", "parking-square": "square-parking",
        "parking-square-off": "square-parking-off", "pause-circle": "circle-pause", "pause-octagon": "octagon-pause",
        "pen-box": "square-pen", "pen-square": "square-pen", "percent-circle": "circle-percent",
        "percent-diamond": "diamond-percent", "percent-square": "square-percent", "pi-square": "square-pi",
        "pie-chart": "chart-pie", "pilcrow-square": "square-pilcrow", "play-circle": "circle-play",
        "play-square": "square-play", "plug-zap-2": "plug-zap", "plus-circle": "circle-plus",
        "plus-square": "square-plus", "podcast": "mic-signal", "power-circle": "circle-power",
        "power-square": "square-power", "rows": "rows-2", "scatter-chart": "chart-scatter", "school-2": "university",
        "scissors-square": "square-scissors", "scissors-square-dashed-bottom": "square-bottom-dashed-scissors",
        "send-horizonal": "send-horizontal", "shield-close": "shield-x", "shield-question": "shield-question-mark",
        "sidebar": "panel-left", "sidebar-close": "panel-left-close", "sidebar-open": "panel-left-open",
        "sigma-square": "square-sigma", "slash-square": "square-slash", "sliders": "sliders-vertical",
        "smile": "face-slightly-smiling", "smile-plus": "face-slightly-smiling-plus",
        "sort-asc": "arrow-up-narrow-wide", "sort-desc": "arrow-down-wide-narrow",
        "split-square-horizontal": "square-split-horizontal", "split-square-vertical": "square-split-vertical",
        "square-gantt-chart": "square-chart-gantt", "stars": "sparkles", "stop-circle": "circle-stop",
        "subtitles": "captions", "table-config": "columns-3-cog", "terminal-square": "square-terminal",
        "test-tube-2": "test-tube-diagonal", "text": "text-align-start", "text-select": "square-dashed-text",
        "text-selection": "square-dashed-text", "train": "tram-front", "trash-2": "trash", "tv-2": "tv-minimal",
        "unlock": "lock-open", "unlock-keyhole": "lock-keyhole-open", "upload-cloud": "cloud-upload",
        "user-2": "user-round", "user-check-2": "user-round-check", "user-circle": "circle-user",
        "user-circle-2": "circle-user-round", "user-cog-2": "user-round-cog", "user-minus-2": "user-round-minus",
        "user-plus-2": "user-round-plus", "user-square": "square-user", "user-square-2": "square-user-round",
        "user-x-2": "user-round-x", "users-2": "users-round", "verified": "badge-check",
        "wallet-2": "wallet-minimal", "wand-2": "wand-sparkles", "waves": "waves-horizontal",
        "wrap-text": "text-wrap", "x-circle": "circle-x", "x-octagon": "octagon-x", "x-square": "square-x",
    ]
}

/// An app's icon at `size` points, in the surrounding foreground style.
public struct WorkspaceAppIcon: View {
    private let shape: LucideShape
    private let size: CGFloat

    /// The icon a manifest's lucide name is; nil is Apps' grid.
    public init(_ name: String?, size: CGFloat = 16) {
        shape = LucideNames.shape(of: name)
        self.size = size
    }

    public init(_ app: WorkspaceApp, size: CGFloat = 16) {
        self.init(app.icon, size: size)
    }

    public var body: some View {
        LucideIcon(shape: shape, size: size).accessibilityHidden(true)
    }
}

extension Image {
    /// The icon as an image, for the few places that take only one (a menu's
    /// item): rasterised once at `size` points, a template that takes the
    /// foreground colour. A view draws `WorkspaceAppIcon` instead, which stays sharp.
    public static func workspaceApp(_ name: String?, size: CGFloat = 16) -> Image {
        Image(lucide: LucideNames.shape(of: name), size: CGSize(width: size, height: size))
    }
}
