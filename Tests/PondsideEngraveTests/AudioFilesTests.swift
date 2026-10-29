import Foundation
import XCTest
@testable import PondsideEngrave

final class AudioFilesTests: XCTestCase {
    private func wav(rate: Int, frames: Int) -> Data {
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        let samples = (0..<frames).flatMap { le(Int(UInt16(bitPattern: Int16($0 % 2 == 0 ? 1000 : -1000))), 2) }
        let fmt: [UInt8] = Array("fmt ".utf8) + le(16, 4) + le(1, 2) + le(1, 2) + le(rate, 4) + le(rate * 2, 4) + le(2, 2) + le(16, 2)
        let data: [UInt8] = Array("data".utf8) + le(samples.count, 4) + samples
        return Data(Array("RIFF".utf8) + le(4 + fmt.count + data.count, 4) + Array("WAVE".utf8) + fmt + data)
    }

    func testPaddingAddsSilenceToTheEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pad-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav(rate: 100, frames: 100).write(to: url)
        XCTAssertTrue(try AudioFiles.padWAV(url, toSeconds: 2.5))
        let info = try XCTUnwrap(WAVInfo(try Data(contentsOf: url)))
        XCTAssertEqual(info.frames, 250)
        XCTAssertEqual(info.seconds, 2.5, accuracy: 1e-9)
        XCTAssertFalse(try AudioFiles.padWAV(url, toSeconds: 1), "never shortens")
    }

    func testOneStaffsTrackWithTheTempoTrack() throws {
        func track(_ name: String) -> [UInt8] {
            let body: [UInt8] = [0x00, 0xFF, 0x03, UInt8(name.utf8.count)] + Array(name.utf8) + [0x00, 0xFF, 0x2F, 0x00]
            let n = body.count
            return Array("MTrk".utf8) + [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + body
        }
        let header: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 3, 1, 0xE0]
        let file = Data(header + track("control") + track("flute") + track("electronics"))
        let tracks = try XCTUnwrap(AudioFiles.midiTracks(file))
        XCTAssertEqual(tracks.tracks.map(\.name), ["control", "flute", "electronics"])
        let stem = try XCTUnwrap(AudioFiles.midi(file, keepingTrack: 2))
        XCTAssertEqual(AudioFiles.midiTracks(stem)?.tracks.map(\.name), ["control", "electronics"])
        XCTAssertEqual([UInt8](stem)[11], 2, "the header counts two tracks")
    }
}
