import Testing

@testable import PeelUI

/// A manifest's lucide `icon` is drawn as that icon: any name lucide has,
/// its older names too, and the grid only for one it has not.
@Suite struct WorkspaceAppIconTests {
    @Test func aLucideNameResolves() {
        #expect(LucideNames.resolve("lightbulb") == "lightbulb")
        #expect(LucideNames.resolve("shield-check") == "shieldCheck")
        #expect(LucideNames.resolve("message-square") == "messageSquare")
        // A name the old table showed as the grid.
        #expect(LucideNames.resolve("phone") == "phone")
        #expect(LucideNames.resolve("grid-3x2") != nil)
    }

    @Test func aSwiftKeywordsNameResolves() {
        // `repeat` is a keyword, so the package's case is `repeatIcon`.
        #expect(LucideNames.resolve("repeat") == "repeatIcon")
        #expect(LucideNames.resolve("package") != nil)
    }

    @Test func aRenamedIconResolvesAsItsCurrentName() {
        #expect(LucideNames.resolve("home") == LucideNames.resolve("house"))
        #expect(LucideNames.resolve("bar-chart-3") == LucideNames.resolve("chart-column"))
        #expect(LucideNames.resolve("check-square") != nil)
    }

    @Test func noNameOrAnUnknownOneIsNotAnIcon() {
        #expect(LucideNames.resolve(nil) == nil)
        #expect(LucideNames.resolve("") == nil)
        #expect(LucideNames.resolve("not-a-lucide-icon") == nil)
        #expect(LucideNames.resolve("square.grid.2x2") == nil)
        // What such an app draws instead exists.
        #expect(LucideNames.resolve(LucideNames.fallback) == "layoutGrid")
    }

    @Test func everyNameTheOldTableKnewStillResolves() {
        for name in [
        "activity", "alarm-clock", "bar-chart", "bar-chart-3", "bell", "book",
        "book-open", "brain", "briefcase", "building", "building-2", "calendar",
        "camera", "chart-bar", "chart-column", "chart-line", "chart-pie", "check-square",
        "circle-dollar-sign", "clock", "code", "cpu", "credit-card", "database",
        "dollar-sign", "eye", "file", "file-text", "flag", "flask-conical",
        "flask-round", "folder", "gauge", "git-branch", "globe", "graduation-cap",
        "heart", "home", "house", "image", "inbox", "kanban",
        "layers", "lightbulb", "line-chart", "list", "list-checks", "list-todo",
        "lock", "mail", "map", "map-pin", "message-circle", "message-square",
        "music", "network", "newspaper", "package", "palette", "pen",
        "pencil", "pie-chart", "puzzle", "receipt", "scale", "search",
        "server", "settings", "shield", "shield-check", "shopping-cart", "sparkles",
        "square-check", "star", "table", "tag", "target", "terminal",
        "test-tube", "trending-up", "trophy", "truck", "user", "users",
        "utensils", "wallet", "workflow", "zap"
        ] {
            #expect(LucideNames.resolve(name) != nil, "\(name)")
        }
    }
}
