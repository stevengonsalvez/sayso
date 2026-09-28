import Foundation
import Testing
@testable import SaysoCore

@Suite("Model Catalog Parity Tests")
struct ModelCatalogParityTests {

    @Test("CloudProviderCatalog contains standard providers and valid models")
    func cloudProviderCatalogValidation() {
        let providers = CloudProviderCatalog.all
        #expect(!providers.isEmpty)
        #expect(providers.count >= 7)

        let providerIds = providers.map(\.id)
        #expect(providerIds.contains("sayso"))
        #expect(providerIds.contains("groq"))
        #expect(providerIds.contains("openai"))
        #expect(providerIds.contains("anthropic"))
        #expect(providerIds.contains("deepseek"))
        #expect(providerIds.contains("ollama"))
        #expect(providerIds.contains("custom"))

        #expect(CloudProviderCatalog.defaultProvider.id == "sayso")

        for provider in providers {
            #expect(!provider.displayName.isEmpty)
            #expect(!provider.keychainServiceIdentifier.isEmpty)

            for model in provider.transcriptionModels {
                #expect(!model.id.isEmpty)
                #expect(!model.displayName.isEmpty)
                #expect(!model.latencyTier.badgeText.isEmpty)
                if let est = model.estimatedLatencyMs {
                    #expect(est > 0)
                }
            }

            for model in provider.cleanupModels {
                #expect(!model.id.isEmpty)
                #expect(!model.displayName.isEmpty)
                #expect(!model.latencyTier.badgeText.isEmpty)
                if let est = model.estimatedLatencyMs {
                    #expect(est > 0)
                }
            }
        }

        let groqProvider = CloudProviderCatalog.findProvider(id: "groq")
        #expect(groqProvider != nil)
        #expect(groqProvider?.displayName == "Groq Cloud")

        let groqWhisper = CloudProviderCatalog.transcriptionModel(providerId: "groq", modelId: "whisper-large-v3-turbo")
        #expect(groqWhisper != nil)
        #expect(groqWhisper?.latencyTier == .fast)

        let nonExistent = CloudProviderCatalog.findProvider(id: "unknown-provider-id")
        #expect(nonExistent == nil)
    }

    @Test("LocalSlmCatalog contains expected SLMs and valid configurations")
    func localSlmCatalogValidation() {
        let slms = LocalSlmCatalog.all
        #expect(slms.count == 4)

        let ids = slms.map(\.id)
        #expect(ids.contains("local-slm/qwen2.5-0.5b"))
        #expect(ids.contains("local-slm/smollm2-360m"))
        #expect(ids.contains("local-slm/qwen2.5-1.5b"))
        #expect(ids.contains("local-slm/phi-3-mini"))

        #expect(LocalSlmCatalog.defaultSlm.id == "local-slm/qwen2.5-0.5b")

        for slm in slms {
            #expect(!slm.displayName.isEmpty)
            #expect(!slm.parameterCount.isEmpty)
            #expect(slm.quantizedSizeMb > 0)
            #expect(!slm.sizeDisplay.isEmpty)
            #expect(!slm.latencyTier.badgeText.isEmpty)
            #expect(slm.fileName.hasSuffix(".gguf"))
            #expect(slm.downloadURL.scheme == "https")
        }

        let found = LocalSlmCatalog.find(id: "local-slm/smollm2-360m")
        #expect(found != nil)
        #expect(found?.parameterCount == "360M")

        let notFound = LocalSlmCatalog.find(id: "unknown-slm-id")
        #expect(notFound == nil)
    }

    @Test("SaysoSettings roundtrips new cloud provider and local SLM fields")
    func settingsRoundtripWithCloudAndSlmFields() throws {
        var settings = SaysoSettings()
        settings.selectedCloudProviderId = "groq"
        settings.selectedCloudModelId = "whisper-large-v3-turbo"
        settings.selectedCloudCleanupProviderId = "anthropic"
        settings.selectedCloudCleanupModelId = "claude-3-5-haiku-20241022"
        settings.selectedLocalSlmModelId = "local-slm/qwen2.5-1.5b"
        settings.selectedLocalAsrModelId = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SaysoSettings.self, from: data)

        #expect(decoded.selectedCloudProviderId == "groq")
        #expect(decoded.selectedCloudModelId == "whisper-large-v3-turbo")
        #expect(decoded.selectedCloudCleanupProviderId == "anthropic")
        #expect(decoded.selectedCloudCleanupModelId == "claude-3-5-haiku-20241022")
        #expect(decoded.selectedLocalSlmModelId == "local-slm/qwen2.5-1.5b")
        #expect(decoded.selectedLocalAsrModelId == "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8")
    }

    @Test("SaysoSettings decodes cleanly from empty JSON with safe defaults")
    func settingsDecodesFromEmptyJsonWithDefaults() throws {
        let emptyJsonData = Data("{}".utf8)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SaysoSettings.self, from: emptyJsonData)

        #expect(decoded.selectedCloudProviderId == "groq")
        #expect(decoded.selectedCloudModelId == "distil-whisper-large-v3-en")
        #expect(decoded.selectedCloudCleanupProviderId == "groq")
        #expect(decoded.selectedCloudCleanupModelId == "llama-3.1-8b-instant")
        #expect(decoded.selectedLocalSlmModelId == "local-slm/qwen2.5-0.5b")
        #expect(decoded.selectedLocalAsrModelId == "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8")
    }

    @Test("LocalModelCatalog maps languages to dedicated neural models and recommendations")
    func localModelCatalogLanguageMapping() {
        let englishModels = LocalModelCatalog.models(for: .english)
        #expect(!englishModels.isEmpty)
        #expect(englishModels.contains { $0.id == "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8" })
        #expect(LocalModelCatalog.recommendedModel(for: .english).id == "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8")

        let tamilModels = LocalModelCatalog.models(for: .tamil)
        #expect(!tamilModels.isEmpty)
        #expect(tamilModels.contains { $0.id == "ai4bharat-indicconformer-ta" })
        #expect(LocalModelCatalog.recommendedModel(for: .tamil).id == "ai4bharat-indicconformer-ta")

        let hindiModels = LocalModelCatalog.models(for: .hindi)
        #expect(!hindiModels.isEmpty)
        #expect(hindiModels.contains { $0.id == "ai4bharat-indicconformer-hi" })
        #expect(LocalModelCatalog.recommendedModel(for: .hindi).id == "ai4bharat-indicconformer-hi")

        let malayalamModels = LocalModelCatalog.models(for: .malayalam)
        #expect(!malayalamModels.isEmpty)
        #expect(malayalamModels.contains { $0.id == "ai4bharat-indicconformer-ml" })
        #expect(LocalModelCatalog.recommendedModel(for: .malayalam).id == "ai4bharat-indicconformer-ml")

        let punjabiModels = LocalModelCatalog.models(for: .punjabi)
        #expect(!punjabiModels.isEmpty)
        #expect(punjabiModels.contains { $0.id == "ai4bharat-indicconformer-pa" })
        #expect(LocalModelCatalog.recommendedModel(for: .punjabi).id == "ai4bharat-indicconformer-pa")
    }

    @Test("DictationLanguage Indic detection and parity with Android featured languages")
    func indicLanguageParity() {
        #expect(DictationLanguage.tamil.isIndic)
        #expect(DictationLanguage.hindi.isIndic)
        #expect(DictationLanguage.malayalam.isIndic)
        #expect(DictationLanguage.punjabi.isIndic)
        #expect(!DictationLanguage.english.isIndic)
        #expect(!DictationLanguage.automatic.isIndic)
    }
}
