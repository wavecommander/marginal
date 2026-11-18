import Foundation
import UIKit

/// The kind of device the app runs on, for text that names it ("this iPhone", "this iPad") and
/// for the device list of a Tactile Texts Cloud account. The app ships for iPhone and iPad
/// (owner decision, 17 November 2026), so a reader's devices can be a mix.
///
/// **Whole sentences, not a noun dropped into one.** `docs/LOCALIZATION_PLAN.md` says never to
/// assemble a sentence from translated fragments, and "this iPad"/"this iPhone" can change the
/// words around them in other languages. So text that names the device is written twice, once per
/// kind, and chosen with `pick(iPad:iPhone:)`; when the strings move into the String Catalog each
/// pair becomes one key with device variations ("Vary by Device"). "iPhone" and "iPad" themselves
/// are product names and are not translated.
nonisolated enum DeviceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case iPhone = "iphone"
    case iPad = "ipad"

    /// The device this app is running on, from its interface idiom (a phone is an iPhone;
    /// everything else, including an iPad app on a Mac, counts as an iPad). Worked out once.
    static let current: DeviceKind = {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .phone ? .iPhone : .iPad }
        }
        // Off the main thread (never in practice: the first use is a screen): the model
        // identifier says the same thing ("iPhone17,1", or the simulator's model).
        let environment = ProcessInfo.processInfo.environment
        return DeviceKind(modelIdentifier: environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineIdentifier())
    }()

    /// The kind a model identifier names: "iPhone…" or "iPod…" is an iPhone, anything else an iPad.
    init(modelIdentifier: String) {
        self = modelIdentifier.hasPrefix("iPhone") || modelIdentifier.hasPrefix("iPod") ? .iPhone : .iPad
    }

    /// "iPhone", "iPad": the product name.
    var name: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        }
    }

    /// The text written for this kind of device.
    func pick<Value>(iPad: Value, iPhone: Value) -> Value {
        self == .iPhone ? iPhone : iPad
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
