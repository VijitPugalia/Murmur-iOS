import Foundation

enum AppGroupResolver {
    static func groups(in profile: Data, base: String) -> [String] {
        // A provisioning profile is a CMS container with an XML plist. Read only group names.
        guard let start = profile.range(of: Data("<plist".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups.filter { $0 == base || $0.hasPrefix(base + ".") }
    }
    static func directory(base: String) -> URL? {
        var identifiers = [base]
        let bundle = Bundle.main.bundleURL
        // The extension can also inspect the containing app's provisioning profile.
        let candidates = [bundle.appendingPathComponent("embedded.mobileprovision"),
            bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("embedded.mobileprovision")]
        for url in candidates {
            if let data = try? Data(contentsOf: url) { identifiers += groups(in: data, base: base) }
        }
        for identifier in identifiers {
            if let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) { return directory }
        }
        return nil
    }
}
