//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import Signal
import XCTest

final class MediaSelectionCoordinatorTest: XCTestCase {

    func testSelectAllProcessesAllItems() {
        let coordinator = MediaSelectionCoordinator<Int>(batchSize: 3, batchPause: .milliseconds(1))
        var processedItems = [Int]()
        let finishedExpectation = expectation(description: "finished")
        var states = [MediaSelectionCoordinator<Int>.State]()
        let cancellable = coordinator.statePublisher.sink { state in
            states.append(state)
            if case .finished = state {
                finishedExpectation.fulfill()
            }
        }

        coordinator.selectAll(items: Array(0..<10)) { item in
            processedItems.append(item)
        }

        waitForExpectations(timeout: 2)
        cancellable.cancel()

        XCTAssertEqual(processedItems, Array(0..<10))
        XCTAssertTrue(states.contains { state in
            if case .inProgress(let progress) = state {
                return progress.selectedCount == 10 && progress.totalCount == 10
            }
            return false
        })
    }

    func testCancelStopsSelection() {
        let coordinator = MediaSelectionCoordinator<Int>(batchSize: 2, batchPause: .milliseconds(50))
        var processedItems = [Int]()
        let cancelledExpectation = expectation(description: "cancelled")
        let cancellable = coordinator.statePublisher.sink { state in
            if case .cancelled = state {
                cancelledExpectation.fulfill()
            }
        }

        coordinator.selectAll(items: Array(0..<50)) { item in
            processedItems.append(item)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            coordinator.cancel()
        }

        waitForExpectations(timeout: 3)
        cancellable.cancel()

        XCTAssertTrue(processedItems.count < 50)
    }
}
