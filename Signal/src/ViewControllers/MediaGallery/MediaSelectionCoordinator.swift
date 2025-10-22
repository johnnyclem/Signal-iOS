//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

/// Coordinates batch selection work for the media gallery without blocking the main actor.
final class MediaSelectionCoordinator<Item> {

    struct Progress: Equatable {
        let selectedCount: Int
        let totalCount: Int

        var fractionCompleted: Double {
            guard totalCount > 0 else { return 1 }
            return Double(selectedCount) / Double(totalCount)
        }
    }

    enum State: Equatable {
        case idle
        case inProgress(Progress)
        case finished
        case cancelled
    }

    private let batchSize: Int
    private let batchPauseNanoseconds: UInt64
    private let stateSubject = CurrentValueSubject<State, Never>(.idle)
    private var selectionTask: Task<Void, Never>?

    init(batchSize: Int = 64, batchPause: DispatchTimeInterval = .milliseconds(20)) {
        precondition(batchSize > 0)
        self.batchSize = batchSize
        switch batchPause {
        case .nanoseconds(let value):
            batchPauseNanoseconds = UInt64(max(value, 0))
        case .microseconds(let value):
            batchPauseNanoseconds = UInt64(max(value, 0)) * 1_000
        case .milliseconds(let value):
            batchPauseNanoseconds = UInt64(max(value, 0)) * 1_000_000
        case .seconds(let value):
            batchPauseNanoseconds = UInt64(max(value, 0)) * 1_000_000_000
        case .never:
            batchPauseNanoseconds = 0
        @unknown default:
            batchPauseNanoseconds = 0
        }
    }

    var statePublisher: AnyPublisher<State, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    func selectAll(items: [Item], handler: @MainActor @escaping (Item) -> Void) {
        cancel()

        guard !items.isEmpty else {
            stateSubject.send(.finished)
            return
        }

        stateSubject.send(.inProgress(Progress(selectedCount: 0, totalCount: items.count)))

        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.selectionTask = nil }
            do {
                var processedCount = 0
                var index = 0
                while index < items.count {
                    try Task.checkCancellation()

                    let upperBound = min(index + self.batchSize, items.count)
                    let batch = Array(items[index..<upperBound])
                    await MainActor.run {
                        batch.forEach { handler($0) }
                    }

                    processedCount = upperBound
                    self.stateSubject.send(.inProgress(Progress(selectedCount: processedCount, totalCount: items.count)))
                    index = upperBound

                    if index < items.count && self.batchPauseNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: self.batchPauseNanoseconds)
                    }
                }
                self.stateSubject.send(.finished)
            } catch is CancellationError {
                self.stateSubject.send(.cancelled)
            }
        }
    }

    func cancel() {
        selectionTask?.cancel()
    }

    func reset() {
        stateSubject.send(.idle)
    }
}
