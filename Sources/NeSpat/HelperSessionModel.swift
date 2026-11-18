import Foundation
import SwiftUI
import NeSpatPrivilegeCore

/// Manual adapter over verified transport. The automatic runtime uses LocalAutomaticBackend.
@MainActor final class HelperSessionModel: ObservableObject {
    enum Status: Equatable { case unknown, off, on, foreign }
    @Published private(set) var status = Status.unknown
    @Published private(set) var busy = false
    @Published private(set) var operationError: String?
    @Published private(set) var deadline: Date?
    private let transport: PrivilegeTransport
    private var ownedSession: UUID?
    private var generation = 0

    init(transport: PrivilegeTransport) { self.transport = transport }

    func enable(minutes: Int? = nil) async { await perform(Request(operation: .begin, minutes: minutes)) }
    func refresh() async { await perform(Request(operation: .status)) }
    func heartbeat() async {
        guard status == .on, let ownedSession else { return }
        await perform(Request(operation: .heartbeat, session: ownedSession))
    }
    func end() async {
        guard let ownedSession else {
            operationError = "Владение сессией не подтверждено; требуется восстановление."
            return
        }
        await perform(Request(operation: .end, session: ownedSession))
    }
    func recover(session: UUID) async { await perform(Request(operation: .recover, session: session)) }
    func close() async {
        generation += 1
        status = .unknown; deadline = nil; busy = false
        operationError = "Связь потеряна; обычный сон не подтверждён."
        // Local ownership history is retained, but is never authority to change global state.
        await transport.close()
    }
    private func perform(_ request: Request) async {
        guard !busy else { return }
        busy = true
        let expected = generation
        defer { if generation == expected { busy = false } }
        do {
            let reply = try await transport.request(request)
            guard generation == expected else { return }
            operationError = nil
            switch reply.state {
            case .enabled:
                status = .off; ownedSession = nil; deadline = nil
                if request.operation == .begin { operationError = "Включение режима не подтверждено." }
            case .disabled:
                if request.operation == .begin, let id = reply.session { ownedSession = id }
                if let id = ownedSession, reply.session == id {
                    status = .on; deadline = reply.deadline // Server's absolute deadline only.
                } else {
                    status = ownedSession == nil ? .foreign : .unknown
                    deadline = nil
                    operationError = "Владение активной сессией не подтверждено."
                }
            case .unknown:
                status = .unknown; deadline = nil
                operationError = "Не удалось подтвердить состояние сна."
            }
        } catch {
            guard generation == expected else { return }
            status = .unknown; deadline = nil
            operationError = "Операция не подтверждена; проверьте состояние и восстановление сна."
        }
    }
}
