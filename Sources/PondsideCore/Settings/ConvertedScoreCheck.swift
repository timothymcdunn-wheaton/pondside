/// Settings musicxml2ly writes that work against LilyPond's defaults, found
/// in a score's files. MusicXML spells out every beam and every
/// cancellation, so the converter turns LilyPond's own off; once someone
/// edits the music by hand (or in Pondside) that leaves new notes unbeamed.
/// Pondside offers once, when such a score is first opened, to put
/// LilyPond's defaults back. (Its `\pointAndClickOff` needs nothing: canvas
/// compiles neutralize it in the session settings, DESIGN.md M2.1 A.)
public enum ConvertedScoreCheck {
    public struct Finding: Sendable, Hashable {
        public var file: String
        public var line: Int
        public var description: String
        /// The setting, and the default to write in the root's settings.
        public var setting: String
        public var value: EngravingValue
    }

    /// Whether `text` says musicxml2ly made it.
    public static func isConverted(_ text: String) -> Bool {
        text.firstRange(of: "musicxml2ly") != nil || text.firstRange(of: "encodingsoftware") != nil
    }

    /// Findings in the converted files among `files` (label, text).
    public static func findings(in files: [(file: String, text: String)]) -> [Finding] {
        var result: [Finding] = []
        for file in files where isConverted(file.text) {
            var line = 0
            for raw in file.text.split(separator: "\n", omittingEmptySubsequences: false) {
                line += 1
                let text = raw.trimmedSpaces
                if text.hasPrefix("%") { continue }
                if text.firstRange(of: "autoBeaming = ##f") != nil {
                    result.append(Finding(file: file.file, line: line, description: "automatic beaming is off",
                                          setting: "score.autoBeaming", value: .bool(true)))
                }
                if text.firstRange(of: "printKeyCancellation = ##f") != nil {
                    result.append(Finding(file: file.file, line: line, description: "key changes don't cancel the old key",
                                          setting: "staff.keyCancellation", value: .bool(true)))
                }
            }
        }
        return result
    }
}
