import Testing
@testable import StudioCore

@Suite struct CatalogTests {
    @Test func idsAreUnique() {
        let ids = Catalog.items.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyItemUsesAKnownCategory() {
        let known = Set(Catalog.categories)
        for item in Catalog.items { #expect(known.contains(item.category), "\(item.title)") }
    }

    @Test func urlsAreWellFormed() {
        for item in Catalog.items {
            #expect(item.videoURL.absoluteString.hasPrefix("https://assets.mixkit.co/videos/\(item.id)/"))
            #expect(item.videoURL.pathExtension == "mp4")
            #expect([720, 1080].contains(item.quality))
            #expect(item.sizeMB > 0)
        }
    }

    @Test func sidebarOrderMatchesBrief() {
        #expect(SidebarSection.allCases.map(\.title) == ["Discover", "My Library", "Editor", "Playlists", "Displays", "Settings"])
    }
}
