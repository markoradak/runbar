import Foundation
import Yams

struct WorkflowYAMLParser: Sendable {
    func parse(fileURL: URL) throws -> WorkflowMetadata {
        let yaml = try String(contentsOf: fileURL, encoding: .utf8)
        return try parse(yaml: yaml, fileName: fileURL.lastPathComponent)
    }

    func parse(yaml: String, fileName: String) throws -> WorkflowMetadata {
        let loaded = try Yams.load(yaml: yaml)
        let mapping = loaded as? [AnyHashable: Any]
        let fallbackName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let name = (mapping?[AnyHashable("name")] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = mapping?[AnyHashable("on")] ?? mapping?[AnyHashable(true)]

        return WorkflowMetadata(
            fileName: fileName,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            events: events(from: trigger)
        )
    }

    private func events(from trigger: Any?) -> [String] {
        let values: [String]
        switch trigger {
        case let scalar as String:
            values = [scalar]
        case let sequence as [Any]:
            values = sequence.compactMap { $0 as? String }
        case let mapping as [AnyHashable: Any]:
            values = mapping.keys.compactMap { $0 as? String }
        default:
            values = []
        }

        return Array(
            Set(
                values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }
}
