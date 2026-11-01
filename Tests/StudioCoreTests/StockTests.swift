import Testing
import Foundation
@testable import StudioCore

@Suite struct StockParserTests {
    let pexels = """
    {"page":1,"per_page":24,"total_results":50,"videos":[
      {"id":3571264,"url":"https://www.pexels.com/video/aerial-view-of-a-forest-3571264/","image":"https://images.pexels.com/a.jpeg","duration":12,
       "user":{"name":"Ada"},
       "video_files":[
         {"link":"https://cdn.example/hd.mp4","width":1920,"height":1080,"file_type":"video/mp4"},
         {"link":"https://cdn.example/uhd.mp4","width":3840,"height":2160,"file_type":"video/mp4"},
         {"link":"https://cdn.example/sd.mp4","width":640,"height":360,"file_type":"video/mp4"},
         {"link":"https://cdn.example/stream.m3u8","width":1920,"height":1080,"file_type":"application/x-mpegURL"},
         {"link":"http://cdn.example/plain.mp4","width":1920,"height":1080,"file_type":"video/mp4"}]},
      {"id":2,"url":"https://www.pexels.com/video/x-2/","video_files":[{"link":"https://cdn.example/p.mp4","width":1080,"height":1920,"file_type":"video/mp4"}]},
      {"id":3,"url":"https://www.pexels.com/video/none-3/","video_files":[]}]}
    """

    let pixabay = """
    {"total":900,"totalHits":500,"hits":[
      {"id":125,"pageURL":"https://pixabay.com/videos/id-125/","tags":"flowers, yellow, blossom, extra","duration":12,"user":"Coverr",
       "videos":{
         "large":{"url":"","width":0,"height":0,"size":0,"thumbnail":""},
         "medium":{"url":"https://cdn.pixabay.com/m.mp4","width":1920,"height":1080,"size":1,"thumbnail":"https://cdn.pixabay.com/m.jpg"},
         "small":{"url":"https://cdn.pixabay.com/s.mp4","width":1280,"height":720,"size":1,"thumbnail":"https://cdn.pixabay.com/s.jpg"},
         "tiny":{"url":"https://cdn.pixabay.com/t.mp4","width":960,"height":540,"size":1,"thumbnail":"https://cdn.pixabay.com/t.jpg"}}}]}
    """

    @Test func pexelsClipsKeepOnlyHTTPSMP4FilesAndGetATitleFromTheirAddress() throws {
        let page = try StockParser.parsePexels(Data(pexels.utf8))
        #expect(page.clips.map(\.providerID) == [3571264, 2])        // the clip with no files is dropped
        let clip = page.clips[0]
        #expect(clip.title == "Aerial view of a forest" && clip.author == "Ada" && clip.duration == 12)
        #expect(clip.files.count == 3)                                // no .m3u8, no plain http
        #expect(clip.id == "pexels-3571264" && clip.libraryTag == "stock:pexels-3571264")
        #expect(page.total == 50 && page.hasMore)
    }

    @Test func bestFileIsTheLargestLandscapeFileUnderTheCap() throws {
        let clip = try #require(StockParser.parsePexels(Data(pexels.utf8)).clips.first)
        #expect(clip.bestFile()?.height == 2160 && clip.resolutionLabel == "4K")
        #expect(clip.bestFile(maxHeight: 1080)?.height == 1080)
        #expect(clip.bestFile(maxHeight: 100)?.height == 360)         // nothing fits: take the smallest
        let portrait = try #require(StockParser.parsePexels(Data(pexels.utf8)).clips.last)
        #expect(portrait.bestFile()?.height == 1920)                  // only portrait exists, so it is used
    }

    @Test func pixabaySkipsUnavailableSizesAndBuildsATitleFromTags() throws {
        let page = try StockParser.parsePixabay(Data(pixabay.utf8), page: 1)
        let clip = try #require(page.clips.first)
        #expect(clip.files.map(\.height) == [1080, 720, 540])         // the empty "large" is ignored
        #expect(clip.title == "Flowers, yellow, blossom" && clip.author == "Coverr")
        #expect(clip.thumbURL?.absoluteString == "https://cdn.pixabay.com/m.jpg")
        #expect(clip.bestFile()?.height == 1080 && clip.resolutionLabel == "HD")
        #expect(page.total == 500 && page.hasMore)
        #expect(try StockParser.parsePixabay(Data(pixabay.utf8), page: 21).hasMore == false)   // 21 * 24 > 500
    }

    @Test func garbageAnswersAreReportedNotCrashedOn() {
        #expect(throws: StockError.unreadable) { try StockParser.parsePexels(Data("<html>".utf8)) }
        #expect(throws: StockError.unreadable) { try StockParser.parsePixabay(Data("{}".utf8)) }
        #expect(throws: StockError.unreadable) { try StockParser.parsePexels(Data("{\"error\":\"x\"}".utf8)) }
    }

    @Test func requestsCarryTheKeyTheRightWay() throws {
        let p = try #require(StockParser.request(for: StockQuery(provider: .pexels, text: "northern lights", page: 2), key: "K1"))
        #expect(p.url?.host == "api.pexels.com" && p.url?.path == "/videos/search")
        #expect(p.value(forHTTPHeaderField: "Authorization") == "K1")
        #expect(p.url?.absoluteString.contains("query=northern%20lights") == true && p.url?.absoluteString.contains("page=2") == true)
        #expect(p.url?.absoluteString.contains("K1") == false)         // never in the address

        let popular = try #require(StockParser.request(for: StockQuery(provider: .pexels, text: "Popular"), key: "K1"))
        #expect(popular.url?.path == "/videos/popular")

        let x = try #require(StockParser.request(for: StockQuery(provider: .pixabay, text: "sea & sky", page: 1), key: "K2"))
        #expect(x.url?.host == "pixabay.com" && x.url?.path == "/api/videos")
        let comps = URLComponents(url: try #require(x.url), resolvingAgainstBaseURL: false)
        #expect(comps?.queryItems?.first(where: { $0.name == "q" })?.value == "sea & sky")   // encoded properly, round-trips
        #expect(comps?.queryItems?.first(where: { $0.name == "key" })?.value == "K2")
        #expect(comps?.queryItems?.first(where: { $0.name == "safesearch" })?.value == "true")
    }

    @Test func pixabayQueriesAreCappedAtTheirLimit() throws {
        let long = String(repeating: "a", count: 300)
        let r = try #require(StockParser.request(for: StockQuery(provider: .pixabay, text: long), key: "K"))
        let q = URLComponents(url: try #require(r.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
        #expect(q?.count == 100)
    }
}
