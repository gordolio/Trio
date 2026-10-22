import Foundation
import Testing
@testable import Trio

@Suite("Settings Search Navigation") struct SettingsSearchTests {
    @Test("Searching 'Dynamic ISF' finds the Dynamic Settings screen") func searchDynamicISF() {
        let results = SettingItems.filteredItems(searchText: "Dynamic ISF")
        #expect(!results.isEmpty)
        let match = results.first { $0.matchedContent == "Dynamic ISF" }
        #expect(match != nil)
        #expect(match?.settingItem.view == .dynamicISF)
        #expect(match?.scrollLabel == "Dynamic ISF")
    }

    @Test("All scrollTargetLabels have valid non-empty targets") func scrollTargetLabelsNonEmpty() {
        for item in SettingItems.allItems {
            guard let labels = item.scrollTargetLabels else { continue }
            for (key, value) in labels {
                #expect(!value.isEmpty)
                #expect(item.searchContents?.contains(key) == true)
            }
        }
    }

    @Test("Every searchContents entry produces at least one result") func allSearchContentsAreSearchable() {
        for item in SettingItems.allItems {
            guard let contents = item.searchContents else { continue }
            for content in contents {
                let results = SettingItems.filteredItems(searchText: content)
                #expect(!results.isEmpty)
            }
        }
    }

    @Test("Every AI prompt search result targets its settings row") func allAIPromptsAreSearchable() {
        for prompt in AIPromptSettings.Prompt.allCases {
            let result = SettingItems.filteredItems(searchText: prompt.titleKey)
                .first { $0.matchedContent == prompt.titleKey && $0.settingItem.view == .aiServiceSettings }
            #expect(result?.scrollLabel == prompt.title)
        }
    }

    @Test("The AI Assistants screen is found by its settings") func aiAssistantsSettingsAreSearchable() {
        let terms = ["Allow meal requests", "Ask on iPhone if no answer"]
        for term in terms {
            let match = SettingItems.filteredItems(searchText: term)
                .first { $0.matchedContent == term && $0.settingItem.view == .aiAssistantsConfig }
            #expect(match != nil, "\(term) isn't found")
        }
        // The old labels are gone from the screen, so they're gone from the search too.
        for term in ["Also ask on iPhone after", "Approval style"] {
            let old = SettingItems.filteredItems(searchText: term)
            #expect(!old.contains { $0.settingItem.view == .aiAssistantsConfig }, "\(term) is still found")
        }
    }

    @Test("The test requests are gone from the settings search") func searchFindsNoTestRequest() {
        #expect(SettingItems.filteredItems(searchText: "test request").isEmpty)
        // The advanced delivery settings went with them.
        for term in ["Send watch answers by", "Wake-up push"] {
            #expect(SettingItems.filteredItems(searchText: term).isEmpty, "\(term) is still found")
        }
    }

    @Test("SearchResultTarget is Hashable and equatable by value") func searchResultTargetHashable() {
        let a = SearchResultTarget(screen: .dynamicISF, scrollLabel: "Dynamic ISF")
        let b = SearchResultTarget(screen: .dynamicISF, scrollLabel: "Dynamic ISF")
        let c = SearchResultTarget(screen: .dynamicISF, scrollLabel: "Adjust Basal")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("SettingsSearchHighlight starts nil and accepts assignments")
    @MainActor func highlightStateTransitions() {
        let highlight = SettingsSearchHighlight()
        #expect(highlight.highlightedSetting == nil)

        highlight.highlightedSetting = "Dynamic ISF"
        #expect(highlight.highlightedSetting == "Dynamic ISF")

        highlight.highlightedSetting = nil
        #expect(highlight.highlightedSetting == nil)
    }

    @Test("SettingsSearchHighlight can be set and cleared in sequence")
    @MainActor func highlightSequentialUpdates() async {
        let highlight = SettingsSearchHighlight()

        highlight.highlightedSetting = "First Setting"
        #expect(highlight.highlightedSetting == "First Setting")

        highlight.highlightedSetting = "Second Setting"
        #expect(highlight.highlightedSetting == "Second Setting")

        highlight.highlightedSetting = nil
        #expect(highlight.highlightedSetting == nil)
    }
}
