import Foundation

/// Tags and their rules in words, for the screens.
public enum TagText {
    /// "título contém “daily” ou “standup” · só você e Tam"; nil when there
    /// is no condition the app knows.
    public static func rules(_ rules: [TagCondition]) -> String? {
        let parts = rules.compactMap(condition)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func condition(_ condition: TagCondition) -> String? {
        let values = condition.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        switch (condition.field, condition.op) {
        case ("title", "contains"): return "título contém " + values.map { "“\($0)”" }.joined(separator: " ou ")
        case ("people", "includes"): return "com " + list(values)
        case ("people", "is"): return "só " + list(["você"] + values)
        default: return nil
        }
    }

    /// Who put the tag on the meeting, for a tooltip.
    public static func source(_ applied: AppliedTag) -> String {
        switch applied.source {
        case TagSource.manual: "Você pôs esta tag"
        case TagSource.rule: rules(applied.tag.rules).map { "Posta pela regra: \($0)" } ?? "Posta por uma regra"
        case TagSource.recurring: "Veio da reunião anterior nesta sala do Meet"
        default: "Posta automaticamente"
        }
    }

    /// "Ana", "Ana e Bia", "Ana, Bia e Rui".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " e " + names.last!
    }
}
