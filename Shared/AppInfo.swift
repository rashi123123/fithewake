import Foundation

enum AppInfo {
    /// Set once, by scripts/generate_project.py, in both Info.plist files.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
}
