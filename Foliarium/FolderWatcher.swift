import CoreServices
import Foundation

/// The events of one FSEvents callback, turned into what to scan.
struct FSEventBatch {
    var items: [ScanItem] = []
    /// Events were dropped, so the only safe thing is to look at everything.
    var rescanAll = false
    /// The watched folder itself was moved, renamed or deleted.
    var rootChanged = false
    var lastEventID: FSEventStreamEventId = 0
}

/// Watches a folder tree with FSEvents, file by file. Started with a past event ID, FSEvents first replays
/// what changed since then, which covers the time the app wasn't running.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let handler: (FSEventBatch) -> Void

    /// `handler` is called on `queue`.
    init(queue: DispatchQueue, handler: @escaping (FSEventBatch) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    func start(path: String, since: FSEventStreamEventId, latency: CFTimeInterval = 1.5) -> Bool {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, FolderWatcher.callback, &context,
                                               [path] as CFArray, since, latency, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    /// Call on the queue the events are delivered on.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        var batch = FSEventBatch()
        for i in 0..<min(count, list.count) {
            let f = Int(flags[i])
            batch.lastEventID = max(batch.lastEventID, ids[i])
            func has(_ flag: Int) -> Bool { f & flag != 0 }
            if has(kFSEventStreamEventFlagHistoryDone) { continue }
            if has(kFSEventStreamEventFlagRootChanged) { batch.rootChanged = true; continue }
            if has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped) {
                batch.rescanAll = true
                continue
            }
            let path = list[i]
            if has(kFSEventStreamEventFlagMustScanSubDirs) {
                batch.items.append(ScanItem(path: path, depth: .tree))
            } else if has(kFSEventStreamEventFlagItemIsDir) {
                // A folder that was created or moved in: everything in it is new here. Other folder events
                // (tags, permissions) don't mean its files changed, so they're ignored.
                if has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRenamed) {
                    batch.items.append(ScanItem(path: path, depth: .tree))
                }
            } else if f == kFSEventStreamEventFlagNone {
                // Folder-level event, as replayed history can be: look at what's directly inside.
                batch.items.append(ScanItem(path: path, depth: .children))
            } else {
                batch.items.append(ScanItem(path: path, depth: .item))
            }
        }
        watcher.handler(batch)
    }
}
