import CoreServices
import Foundation

private final class FSEventCallbackBox: @unchecked Sendable {
    let handler: @Sendable (GitFileEventBatch) -> Void

    init(handler: @escaping @Sendable (GitFileEventBatch) -> Void) {
        self.handler = handler
    }
}

private final class FSEventStreamToken: @unchecked Sendable {
    private let callbackBox: FSEventCallbackBox
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    init(
        paths: [String],
        latency: TimeInterval,
        handler: @escaping @Sendable (GitFileEventBatch) -> Void
    ) throws {
        callbackBox = FSEventCallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<FSEventCallbackBox>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(rawPaths, to: CFArray.self)
            var paths: [String] = []
            paths.reserveCapacity(count)
            for index in 0..<count {
                guard let value = CFArrayGetValueAtIndex(array, index) else { continue }
                let path = unsafeBitCast(value, to: CFString.self) as String
                paths.append(path)
            }
            box.handler(GitFileEventBatch(paths: paths, detectedAt: Date()))
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { throw GitMetadataError.unreadableGitDirectory }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw GitMetadataError.unreadableGitDirectory
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

struct FSEventsGitFileEventSource: GitFileEventSourcing {
    let latency: TimeInterval

    init(latency: TimeInterval = 0.10) {
        self.latency = latency
    }

    func events(for paths: [String]) -> AsyncStream<GitFileEventBatch> {
        AsyncStream { continuation in
            do {
                let token = try FSEventStreamToken(paths: paths, latency: latency) { batch in
                    continuation.yield(batch)
                }
                continuation.onTermination = { _ in token.stop() }
            } catch {
                continuation.finish()
            }
        }
    }
}
