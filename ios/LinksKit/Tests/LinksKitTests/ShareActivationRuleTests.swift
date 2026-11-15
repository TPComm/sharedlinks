import Foundation
import Testing

@Suite("Share extension activation")
struct ShareActivationRuleTests {
    @Test(arguments: [
        ([["public.url"]], true),
        ([["public.plain-text"]], true),
        ([["public.url"], ["public.plain-text"], ["public.jpeg"]], true),
        ([["com.adobe.pdf", "public.file-url"]], false),
        ([["public.jpeg"]], false),
        ([["com.adobe.pdf", "public.file-url"], ["public.url"]], true),
        ([["com.adobe.pdf", "public.file-url"], ["public.plain-text"]], true),
        ([[String]](), false),
        ([[]], false),
    ])
    func activatesOnlyForLinksOrText(_ typeIdentifiers: [[String]], _ activates: Bool) throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Support/LinksShare-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let shareExtension = try #require(plist["NSExtension"] as? [String: Any])
        let attributes = try #require(shareExtension["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(attributes["NSExtensionActivationRule"] as? String)
        let predicate = NSPredicate(format: rule)
        let attachments = typeIdentifiers.map { ["registeredTypeIdentifiers": $0] }
        let input = ["extensionItems": [["attachments": attachments]]]
        #expect(predicate.evaluate(with: input) == activates)
    }
}
