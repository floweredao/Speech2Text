import Foundation
import Testing

/// Sparkle trusts the appcast only when it is signed. With the feed unsigned, whoever can change the feed can offer an
/// old signed build or rewrite its release notes. `generate_appcast` signs the feed when the archived app sets
/// `SURequireSignedFeed`, and Sparkle requires `SUVerifyUpdateBeforeExtraction` for it.
@Test func theAppRequiresASignedUpdateFeed() throws {
    let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
    let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
    #expect(info["SURequireSignedFeed"] as? Bool == true)
    #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
}
