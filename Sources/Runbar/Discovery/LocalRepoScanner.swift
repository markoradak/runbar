import Foundation

struct LocalRepoScanner: Sendable {
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", "vendor", ".build", "Pods", "target", "dist"
    ]

    let maximumDepth: Int
    let workflowParser: WorkflowYAMLParser

    init(
        maximumDepth: Int = 4,
        workflowParser: WorkflowYAMLParser = WorkflowYAMLParser()
    ) {
        self.maximumDepth = maximumDepth
        self.workflowParser = workflowParser
    }

    func scan(codeRoot: URL) throws -> LocalScanResult {
        let values = try? codeRoot.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard values?.isDirectory == true else { throw RepoDiscoveryError.invalidCodeRoot }
        guard values?.isReadable != false else { throw RepoDiscoveryError.unreadableCodeRoot }

        var repositories: [LocalRepository] = []
        var skipped: [SkippedLocalRepository] = []
        try visit(
            directory: codeRoot.standardizedFileURL,
            root: codeRoot.standardizedFileURL,
            depth: 0,
            repositories: &repositories,
            skipped: &skipped
        )

        return LocalScanResult(
            repositories: repositories.sorted { $0.identity.normalizedKey < $1.identity.normalizedKey },
            skippedRepositories: skipped.sorted {
                if $0.relativePath == $1.relativePath { return $0.reason.rawValue < $1.reason.rawValue }
                return $0.relativePath < $1.relativePath
            }
        )
    }

    private func visit(
        directory: URL,
        root: URL,
        depth: Int,
        repositories: inout [LocalRepository],
        skipped: inout [SkippedLocalRepository]
    ) throws {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            inspectRepository(directory, relativeTo: root, repositories: &repositories, skipped: &skipped)
            return
        }

        guard depth < maximumDepth else { return }

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            )
        } catch {
            if depth == 0 { throw RepoDiscoveryError.unreadableCodeRoot }
            return
        }

        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard !Self.skippedDirectoryNames.contains(child.lastPathComponent) else { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            try visit(
                directory: child,
                root: root,
                depth: depth + 1,
                repositories: &repositories,
                skipped: &skipped
            )
        }
    }

    private func inspectRepository(
        _ repositoryURL: URL,
        relativeTo root: URL,
        repositories: inout [LocalRepository],
        skipped: inout [SkippedLocalRepository]
    ) {
        let relativePath = relativePath(of: repositoryURL, from: root)
        guard let configURL = gitConfigURL(repositoryURL: repositoryURL),
              let origin = originURL(configURL: configURL)
        else {
            skipped.append(.init(relativePath: relativePath, reason: .unreadableGitMetadata))
            return
        }

        guard let identity = GitHubOriginNormalizer.normalize(origin) else {
            skipped.append(.init(relativePath: relativePath, reason: .nonGitHubOrigin))
            return
        }

        let workflowFiles = regularWorkflowFiles(repositoryURL: repositoryURL)
        guard !workflowFiles.isEmpty else {
            let githubDirectory = repositoryURL.appendingPathComponent(".github", isDirectory: true)
            let values = try? githubDirectory.resourceValues(forKeys: [.isDirectoryKey])
            let reason: LocalScanSkipReason = values?.isDirectory == true
                ? .githubWithoutWorkflowFiles
                : .noWorkflowFiles
            skipped.append(.init(relativePath: relativePath, reason: reason))
            return
        }

        let workflows = workflowFiles.map { fileURL -> WorkflowMetadata in
            (try? workflowParser.parse(fileURL: fileURL))
                ?? WorkflowMetadata(
                    fileName: fileURL.lastPathComponent,
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    events: []
                )
        }

        repositories.append(
            LocalRepository(
                identity: identity,
                localPath: repositoryURL.path,
                workflows: workflows,
                localActivityAt: localActivityDate(
                    repositoryURL: repositoryURL,
                    workflowFiles: workflowFiles
                )
            )
        )
    }

    private func localActivityDate(repositoryURL: URL, workflowFiles: [URL]) -> Date? {
        let dotGit = repositoryURL.appendingPathComponent(".git")
        let values = try? dotGit.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let gitDirectory: URL?
        if values?.isDirectory == true {
            gitDirectory = dotGit
        } else if values?.isRegularFile == true,
                  let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                  pointer.lowercased().hasPrefix("gitdir:") {
            let rawPath = pointer.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: rawPath, relativeTo: repositoryURL).standardizedFileURL
        } else {
            gitDirectory = nil
        }

        var candidates = workflowFiles + [repositoryURL]
        if let gitDirectory {
            candidates.append(gitDirectory.appendingPathComponent("HEAD"))
            candidates.append(gitDirectory.appendingPathComponent("index"))
        }
        return candidates.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        .compactMap { date in date }
        .max()
    }

    private func gitConfigURL(repositoryURL: URL) -> URL? {
        let dotGit = repositoryURL.appendingPathComponent(".git")
        let values = try? dotGit.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true {
            return dotGit.appendingPathComponent("config")
        }

        guard values?.isRegularFile == true,
              let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
              pointer.lowercased().hasPrefix("gitdir:")
        else {
            return nil
        }

        let rawPath = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirectory = URL(fileURLWithPath: rawPath, relativeTo: repositoryURL).standardizedFileURL
        let commonDirectoryFile = gitDirectory.appendingPathComponent("commondir")
        if let commonPath = try? String(contentsOf: commonDirectoryFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !commonPath.isEmpty {
            return URL(fileURLWithPath: commonPath, relativeTo: gitDirectory)
                .standardizedFileURL
                .appendingPathComponent("config")
        }
        return gitDirectory.appendingPathComponent("config")
    }

    private func originURL(configURL: URL) -> String? {
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        var isOriginSection = false

        for rawLine in config.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let normalized = line.lowercased().replacingOccurrences(of: "'", with: "\"")
                isOriginSection = normalized == "[remote \"origin\"]"
                continue
            }
            guard isOriginSection, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "url" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func regularWorkflowFiles(repositoryURL: URL) -> [URL] {
        let directory = repositoryURL.appendingPathComponent(".github/workflows", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.filter { url in
            let ext = url.pathExtension.lowercased()
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true && (ext == "yml" || ext == "yaml")
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath, path.hasPrefix(rootPath + "/") else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
