/// Coalesces concurrent refresh requests: at most one `operation` runs at a time.
///
/// - `refresh()` waits for a run that **starts after the call** to finish: the one in flight may have read its
///   data before the request (e.g. an app just launched and its icon hasn't been read yet), so it doesn't count;
///   requests arriving together share the same next run.
/// - `refreshInBackground()` starts a run only when idle and doesn't wait (used for policy-driven retries).
@MainActor
public final class RefreshCoalescer {
    private let operation: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var started = 0
    private var completed = 0

    public init(_ operation: @escaping @MainActor () async -> Void) {
        self.operation = operation
    }

    public var isRunning: Bool { task != nil }

    public func refresh() async {
        let wanted = started + 1
        while completed < wanted {
            if let task {
                await task.value
            } else {
                start()
            }
        }
    }

    public func refreshInBackground() {
        guard task == nil else { return }
        start()
    }

    private func start() {
        started += 1
        let generation = started
        let operation = operation
        task = Task { [weak self] in
            await operation()
            // Clean up inside the task body: waiters always see the latest state when they resume (and never
            // await an already finished task again).
            self?.completed = generation
            self?.task = nil
        }
    }
}
