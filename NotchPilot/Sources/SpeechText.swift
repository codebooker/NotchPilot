import Foundation

/// Pure text rules around local speech recognition.
enum SpeechText {
    static let commandPrompt = "Voice commands for a Mac. Open TextEdit. Write a sentence. Type hello world."

    /// Whisper labels non-speech as [BLANK_AUDIO], (water splashing), *gunshot*, or ♪, and near-silence
    /// often decodes as "You" or "Thank you." Those phrases are never commands, but may be dictation.
    static func isNonSpeech(_ text: String, dictation: Bool = true) -> Bool {
        let spoken=text.replacingOccurrences(of:#"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪"#,with:"",options:.regularExpression)
            .trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return spoken.isEmpty || (!dictation && ["you","thank you","thanks for watching"].contains(VoiceCommandQueue.normalized(spoken)))
    }

    /// Commands keep a small command bias. Dictation is conditioned on the text before the caret,
    /// which keeps a sentence's casing across pauses; without context it stays unbiased.
    /// Custom vocabulary steers spelling in both. Bounded well inside Whisper's prompt window.
    static func prompt(dictation: Bool, vocabulary: [String], context: String) -> String {
        var words = ""
        for word in vocabulary where !word.isEmpty && words.count + word.count < 300 { words += (words.isEmpty ? "" : ", ") + word }
        guard dictation else { return commandPrompt + (words.isEmpty ? "" : " Vocabulary: " + words + ".") }
        let vocabularyPart = words.isEmpty ? "" : words + "."
        let room = max(0, 600 - vocabularyPart.count - 1)
        var recent = context.trimmingCharacters(in:.whitespacesAndNewlines)
        if recent.count > room {
            recent = String(recent.suffix(room))
            if let space = recent.firstIndex(where:\.isWhitespace) { recent = String(recent[recent.index(after:space)...]) }
        }
        return [vocabularyPart, recent].filter { !$0.isEmpty }.joined(separator:" ")
    }

    /// Gives whole-word vocabulary matches their saved spelling ("notchpilot" → "NotchPilot").
    static func applyVocabulary(_ text: String, _ vocabulary: [String]) -> String {
        vocabulary.reduce(text) { result, word in
            guard !word.isEmpty else { return result }
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for:word) + #"(?![\p{L}\p{N}])"#
            return result.replacingOccurrences(of:pattern,with:NSRegularExpression.escapedTemplate(for:word),
                                               options:[.regularExpression,.caseInsensitive])
        }
    }
}
