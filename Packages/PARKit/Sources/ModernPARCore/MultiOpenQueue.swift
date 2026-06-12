import Foundation
import Observation

/// "When opening multiple files at the same time: process them one by one" (doc-01 §5.6,
/// `SimultaneousProcessing` off — the original's default). Each window opened in a multi-open
/// enqueues its auto-run here; a ticket holds its place until the previous window's WHOLE
/// pipeline settles (verify → repair → post-process extraction, including any prompts), so
/// disks aren't thrashed and dialogs arrive one at a time. (ROADMAP Phase 7)
///
/// Settlement is driven by the window owning the ticket: it settles when its session goes
/// idle with nothing pending, and on close (which also withdraws a still-queued ticket).
@MainActor
public final class MultiOpenQueue {
    public struct Ticket: Equatable, Sendable {
        let id: UUID
    }

    private struct Entry {
        let ticket: Ticket
        let start: (Ticket) -> Void
    }

    private var pending: [Entry] = []
    private var active: Ticket?

    public init() {}

    /// Runs `start` immediately when the queue is idle; otherwise holds it (FIFO) until every
    /// earlier ticket settles. The ticket is passed INTO the closure (not just returned)
    /// because an idle queue starts synchronously — the caller's return-value assignment has
    /// not happened yet when `start` needs to settle its own ticket on a failure exit.
    @discardableResult
    public func enqueue(_ start: @escaping (Ticket) -> Void) -> Ticket {
        let ticket = Ticket(id: UUID())
        if active == nil {
            active = ticket
            start(ticket)
        } else {
            pending.append(Entry(ticket: ticket, start: start))
        }
        return ticket
    }

    /// The ticket's pipeline finished — or its window closed. Settling the active ticket
    /// starts the next one; settling a queued ticket withdraws it; settling an already
    /// settled ticket is a no-op (windows settle defensively from several events).
    public func settle(_ ticket: Ticket) {
        if active == ticket {
            active = nil
            startNext()
        } else {
            pending.removeAll { $0.ticket == ticket }
        }
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let entry = pending.removeFirst()
        active = entry.ticket
        entry.start(entry.ticket)
    }
}
