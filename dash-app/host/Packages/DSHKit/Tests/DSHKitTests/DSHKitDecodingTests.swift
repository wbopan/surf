import XCTest
@testable import DSHKit

final class DSHKitDecodingTests: XCTestCase {

    // MARK: - session.list

    func testSessionListDecodesAndNormalizesSubagentIds() throws {
        // Shape + surprise captured live: subagent rows carry bare UUID ids.
        let json = """
        {"items":[
          {"sessionId":"d05f5d79-94b9-4062-a334-112e5b934d30","updatedAt":1787533963755,
           "running":true,"blank":false,"parentSessionId":"session-fdb8ec71-8976-4f86-be6e-d233f3434094",
           "origin":"subagent","cwd":"/tmp/x","agentPreset":"standard",
           "projections":{"asOfSeq":2592,"values":{"title":"You are implementing Workstream B",
             "sessionListMetadata":{"blank":false,"lastPromptAt":1787533963755},"todos":null}}},
          {"sessionId":"session-9b806ff1-1df7-4d10-9447-267e7aa93d73","updatedAt":1787534000000,
           "running":false,"blank":true,
           "projections":{"asOfSeq":0,"values":{"title":null,"sessionListMetadata":{"blank":true}}}}
        ]}
        """.data(using: .utf8)!
        let sessions = DSHDecode.sessions(fromValue: json)
        XCTAssertEqual(sessions.count, 2)
        let sub = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sub.id, "session-d05f5d79-94b9-4062-a334-112e5b934d30")
        XCTAssertTrue(sub.isSubagent)
        XCTAssertTrue(sub.running)
        XCTAssertEqual(sub.title, "You are implementing Workstream B")
        XCTAssertEqual(sub.parentSessionId, "session-fdb8ec71-8976-4f86-be6e-d233f3434094")
        XCTAssertEqual(sub.updatedAt.timeIntervalSince1970, 1_787_533_963.755, accuracy: 0.001)
        let blank = try XCTUnwrap(sessions.last)
        XCTAssertNil(blank.title)
        XCTAssertTrue(blank.blank)
        XCTAssertFalse(blank.isSubagent)
    }

    func testSessionListSkipsGarbageRowsAndMissingFields() {
        let json = """
        {"items":[
          "not an object",
          {"updatedAt":123,"running":"yes"},
          {"sessionId":""},
          {"sessionId":"session-ok-1"},
          {"sessionId":"session-ok-2","running":true,"projections":{"values":{"title":"T"}}}
        ]}
        """.data(using: .utf8)!
        let sessions = DSHDecode.sessions(fromValue: json)
        XCTAssertEqual(sessions.map(\.id), ["session-ok-1", "session-ok-2"])
        XCTAssertFalse(sessions[0].running)              // default
        XCTAssertEqual(sessions[0].updatedAt, Date(timeIntervalSince1970: 0)) // missing → default
        XCTAssertEqual(sessions[1].title, "T")
        XCTAssertTrue(sessions[1].running)
    }

    func testSessionListGarbageRootYieldsEmpty() {
        XCTAssertEqual(DSHDecode.sessions(fromValue: Data("[1,2,3]".utf8)), [])
        XCTAssertEqual(DSHDecode.sessions(fromValue: Data("null".utf8)), [])
        XCTAssertEqual(DSHDecode.sessions(fromValue: Data("garbage".utf8)), [])
    }

    // MARK: - workspace.list

    func testWorkspaceListDecodes() throws {
        let json = """
        {"items":[
          {"workspaceId":"53f1833e","path":"/Users/x/Repos/taste-bench","title":"taste-bench",
           "sessionIds":["session-f418","session-67f6"],
           "createdAt":"2026-08-23T08:04:29.206Z","updatedAt":"2026-08-23T08:25:31.317Z"},
          {"workspaceId":"broken"},
          {"workspaceId":"minimal","sessionIds":42,"title":null}
        ],"archivedSessionIds":["session-b5f2","session-dead", 7]}
        """.data(using: .utf8)!
        let (items, archived) = DSHDecode.workspaces(fromValue: json)
        XCTAssertEqual(items.count, 3) // "broken" keeps id with defaulted fields
        XCTAssertEqual(items[1].id, "broken")
        XCTAssertEqual(items[1].path, "")
        XCTAssertEqual(items[1].sessionIds, [])
        XCTAssertEqual(items[0].sessionIds, ["session-f418", "session-67f6"])
        XCTAssertEqual(items[0].title, "taste-bench")
        XCTAssertEqual(archived, ["session-b5f2", "session-dead"])
        XCTAssertEqual(items[2].sessionIds, []) // garbage sessionIds → default
        XCTAssertEqual(items[2].title, "")     // null title → default
    }

    // MARK: - Envelope

    func testEnvelopeUnwrapSuccessAndEcho() throws {
        let ok = Data("""
        {"type":"server-response","rpcId":"r-1","result":{"ok":true,"value":{"version":"0.0.1","cwd":"/Users/x"}}}
        """.utf8)
        let value = try DSHWire.unwrapEnvelope(ok, expectedRpcId: "r-1").get()
        XCTAssertEqual(DSHDecode.hostInfo(fromValue: value)?.version, "0.0.1")

        let mismatch = DSHWire.unwrapEnvelope(ok, expectedRpcId: "other")
        guard case .failure(.rpcIdMismatch) = mismatch else {
            return XCTFail("expected rpcIdMismatch")
        }
    }

    func testEnvelopeBusinessError() {
        let err = Data("""
        {"type":"server-response","rpcId":"r-2","result":{"ok":false,"error":{"code":"session-not-found","message":"nope"}}}
        """.utf8)
        guard case .failure(.server(let code, let message)) = DSHWire.unwrapEnvelope(err, expectedRpcId: "r-2") else {
            return XCTFail("expected server error")
        }
        XCTAssertEqual(code, "session-not-found")
        XCTAssertEqual(message, "nope")
    }

    func testRequestBodyConstruction() throws {
        let body = try XCTUnwrap(DSHWire.makeRequestBody(
            method: "session.list", payloadJSON: Data("{}".utf8), rpcId: "abc"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "client-request")
        XCTAssertEqual(obj["rpcId"] as? String, "abc")
        XCTAssertEqual(obj["method"] as? String, "session.list")
        XCTAssertEqual((obj["payload"] as? [String: Any])?.count, 0)
    }

    // MARK: - Event frames

    func testFrameDecoding() {
        let sessionEvent = Data("""
        {"type":"server-request","rpcId":1,"method":"session/event",
         "payload":{"sessionId":"session-abc","event":{"type":"message/delta","seq":12,"data":"..."}}}
        """.utf8)
        XCTAssertEqual(DSHWire.decodeFrame(sessionEvent),
                       .sessionEvent(sessionId: "session-abc", type: "message/delta", seq: 12))

        let status = Data("""
        {"type":"server-request","rpcId":2,"method":"host/session-status",
         "payload":{"sessionId":"abc-123","running":false}}
        """.utf8)
        XCTAssertEqual(DSHWire.decodeFrame(status),
                       .hostSessionStatus(sessionId: "session-abc-123", running: false))

        let unknown = Data("""
        {"type":"server-request","rpcId":3,"method":"future/frame","payload":{}}
        """.utf8)
        XCTAssertEqual(DSHWire.decodeFrame(unknown), .unknown(method: "future/frame"))

        XCTAssertNil(DSHWire.decodeFrame(Data("not json".utf8)))
        XCTAssertNil(DSHWire.decodeFrame(Data("{\"method\":\"session/event\"}".utf8))) // no sessionId
    }

    func testNormalizeSessionId() {
        XCTAssertEqual(DSHDecode.normalizeSessionId("abc"), "session-abc")
        XCTAssertEqual(DSHDecode.normalizeSessionId("session-abc"), "session-abc")
    }
}
