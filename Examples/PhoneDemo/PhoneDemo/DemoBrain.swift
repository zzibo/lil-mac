import Foundation
import LilMac

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which model the demo talks to. Read at call time, so running agents follow the picker.
enum DemoBrain: String, CaseIterable, Identifiable {
    case fake, apple, openRouter

    static let key = "demoBrain"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fake: "Fake"
        case .apple: "Apple"
        case .openRouter: "OpenRouter"
        }
    }

    static var current: DemoBrain {
        get { UserDefaults.standard.string(forKey: key).flatMap(DemoBrain.init) ?? .fake }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    func provider(apiKey: String?) -> any Provider {
        switch self {
        case .fake: return FakeProvider()
        case .openRouter: return OpenAICompatible(model: "anthropic/claude-haiku-5.5", apiKey: apiKey)
        case .apple:
            #if canImport(FoundationModels)
            if #available(iOS 26, *) { return AppleOnDevice() }
            #endif
            return NeedsiOS26()
        }
    }
}

private struct NeedsiOS26: Provider {
    func send(_ request: ModelRequest) async throws -> ModelReply { throw ProviderError.unsupported("needs iOS 26") }
}

/// Why Apple's on-device model can't run, or nil when it can.
func appleModelUnavailableReason() -> String? {
    #if canImport(FoundationModels)
    guard #available(iOS 26, *) else { return "needs iOS 26" }
    switch SystemLanguageModel.default.availability {
    case .available: return nil
    case .unavailable(.appleIntelligenceNotEnabled): return "not enabled: turn on Apple Intelligence"
    case .unavailable(.modelNotReady): return "still downloading"
    case .unavailable(.deviceNotEligible): return "this iPhone isn't eligible"
    case .unavailable: return "unavailable"
    }
    #else
    return "needs iOS 26"
    #endif
}

func appleModelLine() -> String { "Apple model: " + (appleModelUnavailableReason() ?? "ready") }
