import Foundation

enum GitMetadataError: Error, Equatable, Sendable {
    case missingGitMetadata
    case unreadableGitDirectory
    case unreadableHead
}

enum GitReferenceStorage: String, Codable, Equatable, Sendable {
    case none
    case loose
    case packed
}

enum GitReferenceSignal: String, Codable, Sendable {
    case looseRemoteRef = "loose_remote_ref"
    case packedRefs = "packed_refs"
    case looseAndPacked = "loose_and_packed"
}

struct GitRepositoryMetadata: Equatable, Sendable {
    let repositoryPath: String
    let gitDirectoryPath: String
    let commonGitDirectoryPath: String
    let looseRemoteRefsPath: String
    let packedRefsPath: String
    let headPath: String
    let headReferencePath: String?
    let watchRootPaths: [String]
}

struct GitWatchSnapshot: Equatable, Sendable {
    let looseRemoteRefsFingerprint: String
    let hasLooseRemoteReference: Bool
    let packedRefsFingerprint: String?
    let currentSHA: String?

    var referenceStorage: GitReferenceStorage {
        let hasLoose = hasLooseRemoteReference
        let hasPacked = packedRefsFingerprint?.contains(" refs/remotes/origin/") == true
        switch (hasLoose, hasPacked) {
        case (false, false): return .none
        case (true, false): return .loose
        case (false, true): return .packed
        case (true, true): return .loose
        }
    }
}

struct GitMetadataResolver: Sendable {
    func resolve(repositoryPath: String) throws -> GitRepositoryMetadata {
        let repositoryURL = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        let dotGit = repositoryURL.appendingPathComponent(".git")
        let values = try? dotGit.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

        let gitDirectory: URL
        let commonGitDirectory: URL
        if values?.isDirectory == true {
            gitDirectory = dotGit
            commonGitDirectory = dotGit
        } else if values?.isRegularFile == true {
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                  pointer.lowercased().hasPrefix("gitdir:")
            else { throw GitMetadataError.missingGitMetadata }
            let rawPath = pointer
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else { throw GitMetadataError.missingGitMetadata }
            gitDirectory = URL(fileURLWithPath: rawPath, relativeTo: repositoryURL).standardizedFileURL

            let commonDirectoryFile = gitDirectory.appendingPathComponent("commondir")
            if let commonPath = try? String(contentsOf: commonDirectoryFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !commonPath.isEmpty {
                commonGitDirectory = URL(fileURLWithPath: commonPath, relativeTo: gitDirectory)
                    .standardizedFileURL
            } else {
                commonGitDirectory = gitDirectory
            }
        } else {
            throw GitMetadataError.missingGitMetadata
        }

        let gitValues = try? gitDirectory.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        let commonValues = try? commonGitDirectory.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard gitValues?.isDirectory == true,
              gitValues?.isReadable != false,
              commonValues?.isDirectory == true,
              commonValues?.isReadable != false
        else { throw GitMetadataError.unreadableGitDirectory }

        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? readTrimmed(headURL), !head.isEmpty else {
            throw GitMetadataError.unreadableHead
        }
        let headReferencePath = referenceName(in: head).map { reference in
            referenceURL(reference, gitDirectory: gitDirectory, commonGitDirectory: commonGitDirectory).path
        }
        let looseRemoteRefs = commonGitDirectory.appendingPathComponent("refs/remotes/origin", isDirectory: true)
        let packedRefs = commonGitDirectory.appendingPathComponent("packed-refs")

        var watchRoots: [String] = [commonGitDirectory.path]
        if gitDirectory != commonGitDirectory {
            watchRoots.append(gitDirectory.path)
        }
        let looseValues = try? looseRemoteRefs.resourceValues(forKeys: [.isDirectoryKey])
        if looseValues?.isDirectory == true {
            watchRoots.append(looseRemoteRefs.path)
        }
        if let headReferencePath {
            watchRoots.append(URL(fileURLWithPath: headReferencePath).deletingLastPathComponent().path)
        }

        return GitRepositoryMetadata(
            repositoryPath: repositoryURL.path,
            gitDirectoryPath: gitDirectory.path,
            commonGitDirectoryPath: commonGitDirectory.path,
            looseRemoteRefsPath: looseRemoteRefs.path,
            packedRefsPath: packedRefs.path,
            headPath: headURL.path,
            headReferencePath: headReferencePath,
            watchRootPaths: Array(Set(watchRoots)).sorted()
        )
    }

    func snapshot(metadata: GitRepositoryMetadata) throws -> GitWatchSnapshot {
        let looseRemoteRefsDirectory = URL(fileURLWithPath: metadata.looseRemoteRefsPath)
        return GitWatchSnapshot(
            looseRemoteRefsFingerprint: looseRemoteFingerprint(directory: looseRemoteRefsDirectory),
            hasLooseRemoteReference: hasLooseRemoteReference(directory: looseRemoteRefsDirectory),
            packedRefsFingerprint: try? String(
                contentsOfFile: metadata.packedRefsPath,
                encoding: .utf8
            ),
            currentSHA: try currentSHA(metadata: metadata)
        )
    }

    func currentSHA(metadata: GitRepositoryMetadata) throws -> String? {
        let head = try readTrimmed(URL(fileURLWithPath: metadata.headPath))
        if let reference = referenceName(in: head) {
            let gitDirectory = URL(fileURLWithPath: metadata.gitDirectoryPath)
            let commonDirectory = URL(fileURLWithPath: metadata.commonGitDirectoryPath)
            let looseReference = referenceURL(
                reference,
                gitDirectory: gitDirectory,
                commonGitDirectory: commonDirectory
            )
            if let sha = try? readTrimmed(looseReference), isSHA(sha) {
                return sha.lowercased()
            }
            return packedSHA(
                reference: reference,
                packedRefsURL: URL(fileURLWithPath: metadata.packedRefsPath)
            )
        }
        return isSHA(head) ? head.lowercased() : nil
    }

    private func referenceURL(
        _ reference: String,
        gitDirectory: URL,
        commonGitDirectory: URL
    ) -> URL {
        let perWorktree = gitDirectory.appendingPathComponent(reference)
        if FileManager.default.fileExists(atPath: perWorktree.path) {
            return perWorktree
        }
        return commonGitDirectory.appendingPathComponent(reference)
    }

    private func referenceName(in head: String) -> String? {
        guard head.hasPrefix("ref:") else { return nil }
        let reference = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return reference.isEmpty ? nil : reference
    }

    private func packedSHA(reference: String, packedRefsURL: URL) -> String? {
        guard let contents = try? String(contentsOf: packedRefsURL, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \Character.isNewline) {
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1] == Substring(reference) else { continue }
            let sha = String(parts[0])
            return isSHA(sha) ? sha.lowercased() : nil
        }
        return nil
    }

    private func looseRemoteFingerprint(directory: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var entries: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let relative = fileURL.path.dropFirst(directory.path.count)
            let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "<unreadable>"
            entries.append("\(relative):\(contents)")
        }
        return entries.sorted().joined(separator: "\n")
    }

    private func hasLooseRemoteReference(directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true,
                  let contents = try? readTrimmed(fileURL)
            else { continue }
            if isSHA(contents) { return true }
        }
        return false
    }

    private func readTrimmed(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSHA(_ value: String) -> Bool {
        guard value.count == 40 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(Character(String(scalar))) ||
                ("a"..."f").contains(Character(String(scalar).lowercased()))
        }
    }
}
