import Foundation
import XCTest
@testable import PondsideEngrave

final class MockupTests: XCTestCase {
    /// A minimal WAV: RIFF header, fmt, an unrelated chunk, then data.
    func wav(format: Int, bits: Int, rate: Int = 48000, channels: Int = 2, samples: [Double]) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16 & 0xFFFF) }
        var body = Data()
        for s in samples {
            switch (format, bits) {
            case (1, 16):
                let v = UInt16(bitPattern: Int16(max(-32768, min(32767, (s * 32767).rounded()))))
                body.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)])
            case (1, 24):
                let v = Int((s * 8_388_607).rounded()) & 0xFF_FFFF
                body.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF)])
            default:
                let v = Float(s).bitPattern
                body.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)])
            }
        }
        d.append(contentsOf: Array("RIFF".utf8)); u32(4 + 24 + 12 + 8 + body.count)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(format); u16(channels); u32(rate); u32(rate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        d.append(contentsOf: Array("LIST".utf8)); u32(3); d.append(contentsOf: [1, 2, 3, 0])   // odd size: padded
        d.append(contentsOf: Array("data".utf8)); u32(body.count)
        d.append(body)
        return d
    }

    func sine(_ n: Int, amplitude: Double) -> [Double] {
        (0..<n).map { amplitude * sin(Double($0) * 2 * .pi * 440 / 48000) }
    }

    func testMeasuresPCMAndFloat() throws {
        for (format, bits) in [(1, 16), (1, 24), (3, 32)] {
            let info = try XCTUnwrap(WAVInfo(wav(format: format, bits: bits, samples: sine(9600, amplitude: 0.5))), "\(format)/\(bits)")
            XCTAssertEqual(info.sampleRate, 48000)
            XCTAssertEqual(info.channels, 2)
            XCTAssertEqual(info.frames, 4800)
            XCTAssertEqual(info.seconds, 0.1, accuracy: 1e-9)
            XCTAssertEqual(info.peak, 0.5, accuracy: 0.001)
            XCTAssertEqual(info.rms, 0.5 / 2.squareRoot(), accuracy: 0.002)
            XCTAssertFalse(info.isSilent)
        }
    }

    func testSilenceAndRateAreDetected() throws {
        let silent = try XCTUnwrap(WAVInfo(wav(format: 1, bits: 16, samples: [Double](repeating: 0, count: 1000))))
        XCTAssertTrue(silent.isSilent)
        let at44 = try XCTUnwrap(WAVInfo(wav(format: 1, bits: 16, rate: 44100, samples: sine(100, amplitude: 0.1))))
        XCTAssertEqual(at44.sampleRate, 44100)
        XCTAssertNil(WAVInfo(Data("not a wav".utf8)))
    }

    func testCacheKeysChangeWithEverythingThatChangesTheAudio() {
        let a = MockupRenderer(sampleRate: 48000), b = MockupRenderer(sampleRate: 44100)
        let midi = Data([0x4D, 0x54, 0x68, 0x64, 1, 2, 3])
        XCTAssertEqual(a.cacheKey(midi: midi, renderer: .musescore), a.cacheKey(midi: midi, renderer: .musescore))
        XCTAssertNotEqual(a.cacheKey(midi: midi, renderer: .musescore), b.cacheKey(midi: midi, renderer: .musescore))
        XCTAssertNotEqual(a.cacheKey(midi: midi, renderer: .musescore), a.cacheKey(midi: midi + [4], renderer: .musescore))
        XCTAssertNotEqual(a.cacheKey(midi: midi, renderer: .musescore), a.cacheKey(midi: midi, renderer: .fluidsynth))
    }
}
