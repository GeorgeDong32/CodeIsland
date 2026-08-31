import XCTest
@testable import CodeIslandCore

@MainActor
final class CodexTransportAdapterTests: XCTestCase {
    private let session = SessionRef(provider: "codex", providerSessionID: "thread-1", generation: 1)

    func testRequestUserInputNormalizesStableQuestionSchemaAndSecretContent() throws {
        let adapter = CodexTransportAdapter(idFactory: DeterministicIDFactory())
        let generation = adapter.openClient()
        let message = try makeRequest(id: "r-1", threadID: "thread-1", questions: [
            [
                "id": "q1",
                "question": "Which plan?",
                "isSecret": true,
                "multiSelect": true,
                "options": [["label": "A"], ["label": "B"]],
            ],
            [
                "id": "q2",
                "question": "Reason?",
            ],
        ])
        let result = adapter.receive(message, session: session, generation: generation,
                                     sink: ClosureCodexResponseSink { _, _ in true })

        guard case let .question(question) = result else { return XCTFail("expected typed question arrival") }
        XCTAssertEqual(question.identity.requestID, "string:r-1")
        XCTAssertEqual(question.identity.clientGeneration, generation)
        XCTAssertEqual(question.arrival.id.correlation,
                       .stable(StableRequestKey(upstreamID: "string:r-1", kind: .question, discriminator: "thread-1")))
        XCTAssertEqual(question.arrival.behavior,
                       .blocking(ResolutionCapabilities(questionActions: [.abandon])))
        guard case let .question(content) = question.arrival.content else { return XCTFail("expected question content") }
        XCTAssertEqual(content.answerSchema.keysInProviderOrder, ["q1", "q2"])
        XCTAssertEqual(content.items[0].prompt.sensitivity, .secret)
        XCTAssertTrue(content.items[0].allowsMultiple)
        XCTAssertEqual(content.items[0].options.map(\.key), ["option_1", "option_2"])
        guard case let .response(token) = question.arrival.channel else { return XCTFail("expected response channel") }
        XCTAssertEqual(token.session, session)
    }

    func testSameRequestIDAndGenerationIsDeduplicatedBeforeCenterIngress() throws {
        let adapter = CodexTransportAdapter(idFactory: DeterministicIDFactory())
        let generation = adapter.openClient()
        let message = try makeRequest(id: "r-dup", threadID: "thread-1", questions: [["id": "q", "question": "Pick"]])
        let sink = ClosureCodexResponseSink { _, _ in true }

        guard case .question = adapter.receive(message, session: session, generation: generation, sink: sink) else {
            return XCTFail("first request must be accepted")
        }
        XCTAssertEqual(adapter.receive(message, session: session, generation: generation, sink: sink), .duplicate)
    }

    func testAnswerIsEncodedByStableQuestionKeyAndDeliveredOnlyOnce() throws {
        let adapter = CodexTransportAdapter(idFactory: DeterministicIDFactory())
        let generation = adapter.openClient()
        let message = try makeRequest(id: "r-answer", threadID: "thread-1", questions: [["id": "q1", "question": "Pick"]])
        var sent: [(CodexRequestID, [String: Any])] = []
        let sink = ClosureCodexResponseSink { id, result in
            sent.append((id, result))
            return true
        }
        guard case let .question(arrival) = adapter.receive(message, session: session, generation: generation, sink: sink) else {
            return XCTFail("expected question")
        }
        guard case let .response(token) = arrival.arrival.channel else { return XCTFail("expected response token") }
        let effect = ResolutionEffect(
            effectID: adapter.idFactory.makeEffectID(),
            requestID: arrival.arrival.id,
            token: token,
            command: .answer([QuestionAnswer(questionKey: "q1", values: [.option("A"), .custom(SensitiveText("own text"))])])
        )
        var events: [InteractionAdapterEvent] = []
        adapter.execute([.deliverResolution(effect)]) { events.append($0) }
        adapter.execute([.deliverResolution(effect)]) { events.append($0) }

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0, .string("r-answer"))
        let answers = try XCTUnwrap(sent[0].1["answers"] as? [String: Any])
        let q1 = try XCTUnwrap(answers["q1"] as? [String: Any])
        XCTAssertEqual(q1["answers"] as? [String], ["A", "own text"])
        XCTAssertEqual(events, [.resolutionSucceeded(effect.effectID, request: arrival.arrival.id, token: token)])
    }

    func testReplacementRejectsLateOldClientAckButNewGenerationCanArrive() throws {
        let adapter = CodexTransportAdapter(idFactory: DeterministicIDFactory())
        let firstGeneration = adapter.openClient()
        let message = try makeRequest(id: "r-old", threadID: "thread-1", questions: [["id": "q", "question": "Old"]])
        let sink = ClosureCodexResponseSink { _, _ in XCTFail("stale request must not reply"); return false }
        guard case let .question(old) = adapter.receive(message, session: session, generation: firstGeneration, sink: sink) else {
            return XCTFail("expected old request")
        }
        let secondGeneration = adapter.replaceClient()
        XCTAssertEqual(adapter.externallyResolve(requestID: old.codexRequestID, threadID: "thread-1", generation: firstGeneration), .staleClient)
        XCTAssertEqual(adapter.receive(message, session: session, generation: firstGeneration, sink: sink), .staleClient)

        let newMessage = try makeRequest(id: "r-new", threadID: "thread-1", questions: [["id": "q", "question": "New"]])
        guard case let .question(new) = adapter.receive(newMessage, session: session, generation: secondGeneration,
                                                        sink: ClosureCodexResponseSink { _, _ in true }) else {
            return XCTFail("new generation must be accepted")
        }
        XCTAssertNotEqual(old.identity, new.identity)
    }

    func testExternalResolvedMatchesRequestIDNotOnlyThread() throws {
        let adapter = CodexTransportAdapter(idFactory: DeterministicIDFactory())
        let generation = adapter.openClient()
        let firstMessage = try makeRequest(id: 1, threadID: "thread-1", questions: [["id": "q1", "question": "First"]])
        let secondMessage = try makeRequest(id: 2, threadID: "thread-1", questions: [["id": "q2", "question": "Second"]])
        guard case let .question(first) = adapter.receive(firstMessage, session: session, generation: generation,
                                                          sink: ClosureCodexResponseSink { _, _ in true }),
              case let .question(second) = adapter.receive(secondMessage, session: session, generation: generation,
                                                           sink: ClosureCodexResponseSink { _, _ in true }) else {
            return XCTFail("expected two independent questions")
        }
        XCTAssertEqual(adapter.externallyResolve(requestID: first.codexRequestID, threadID: "thread-1", generation: generation),
                       .externallyResolved(first.arrival.id))
        XCTAssertEqual(adapter.externallyResolve(requestID: second.codexRequestID, threadID: "thread-1", generation: generation),
                       .externallyResolved(second.arrival.id))
        XCTAssertEqual(adapter.externallyResolve(requestID: first.codexRequestID, threadID: "thread-1", generation: generation), .ignored)
    }

    private func makeRequest(id: Any, threadID: String, questions: [[String: Any]]) throws -> CodexJSONRPCMessage {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "item/tool/requestUserInput",
            "params": ["threadId": threadID, "questions": questions],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try XCTUnwrap(CodexAppServerClient.parseMessage(data))
    }
}
