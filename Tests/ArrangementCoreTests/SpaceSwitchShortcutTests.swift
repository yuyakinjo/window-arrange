import Foundation
import Testing
@testable import ArrangementCore

struct SpaceSwitchShortcutTests {
    @Test func defaultsAndEnabledOnlyOverrides() throws {
        #expect(try SpaceSwitchShortcut.resolve(.left, hotKeys: [:]).keyCode == 123)
        #expect(try SpaceSwitchShortcut.resolve(.right, hotKeys: ["81": ["enabled": true]]).keyCode == 124)
    }

    @Test func honorsCustomControlIAndOFromPropertyList() throws {
        let dictionary: [String: Any] = [
            "79": ["enabled": true, "value": ["type": "standard", "parameters": [105, 34, 262144]]],
            "81": ["enabled": true, "value": ["type": "standard", "parameters": [111, 31, 262144]]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        let keys = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let left = try SpaceSwitchShortcut.resolve(.left, hotKeys: keys)
        let right = try SpaceSwitchShortcut.resolve(.right, hotKeys: keys)
        #expect(left.keyCode == 34 && left.modifiers == 262144)
        #expect(right.keyCode == 31 && right.modifiers == 262144)
    }

    @Test func disabledOrMalformedShortcutNeverSendsDefaultKey() {
        #expect(throws: SpaceSwitchShortcut.ResolutionError.self) {
            try SpaceSwitchShortcut.resolve(.left, hotKeys: ["79": ["enabled": false]])
        }
        for value: [String: Any] in [
            ["type": "standard", "parameters": [0, 65535, 0]],
            ["type": "standard", "parameters": [0, 31]],
            ["type": "standard", "parameters": [0, 31, -1]],
            ["type": "mouse", "parameters": [0, 31, 262144]]
        ] {
            #expect(throws: SpaceSwitchShortcut.ResolutionError.self) {
                try SpaceSwitchShortcut.resolve(.right, hotKeys: ["81": ["enabled": true, "value": value]])
            }
        }
    }
}
