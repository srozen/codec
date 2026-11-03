import Testing
@testable import CodecCore

@Suite("TextSearch")
struct TextSearchTests {
    private func find(_ query: String, in line: String, _ options: FindOptions = FindOptions()) -> [String] {
        guard let expression = TextSearch.expression(for: query, options: options) else { return [] }
        let characters = Array(line)
        return TextSearch.matches(of: expression, in: characters).map { String(characters[$0]) }
    }

    @Test func findsEveryOccurrenceIgnoringCase() {
        #expect(find("error", in: "Error: one error, ERRORS") == ["Error", "error", "ERROR"])
    }

    @Test func caseSensitive() {
        #expect(find("error", in: "Error: one error", FindOptions(caseSensitive: true)) == ["error"])
    }

    @Test func takesTheQueryLiterallyUnlessItsARegex() {
        #expect(find("a.c", in: "abc a.c") == ["a.c"])
        #expect(find("a.c", in: "abc a.c", FindOptions(regex: true)) == ["abc", "a.c"])
        #expect(find("[0-9]+ms", in: "took 12ms, then 340ms", FindOptions(regex: true)) == ["12ms", "340ms"])
    }

    @Test func wholeWords() {
        #expect(find("log", in: "log logger catalog log.", FindOptions(wholeWord: true)) == ["log", "log"])
        #expect(find("a|b", in: "a ab b", FindOptions(regex: true, wholeWord: true)) == ["a", "b"])
    }

    @Test func noExpressionForAnEmptyQueryOrABadPattern() {
        #expect(TextSearch.expression(for: "", options: FindOptions()) == nil)
        #expect(TextSearch.expression(for: "(", options: FindOptions(regex: true)) == nil)
        #expect(TextSearch.expression(for: "(", options: FindOptions()) != nil)
    }

    @Test func leavesOutEmptyMatches() {
        #expect(find("x*", in: "ab xx", FindOptions(regex: true)) == ["xx"])
    }

    @Test func countsInCharactersNotUTF16() throws {
        let characters = Array("🚀 build ✅ done")
        let expression = try #require(TextSearch.expression(for: "done", options: FindOptions()))
        #expect(TextSearch.matches(of: expression, in: characters) == [10..<14])
        let rocket = try #require(TextSearch.expression(for: "🚀", options: FindOptions()))
        #expect(TextSearch.matches(of: rocket, in: characters) == [0..<1])
    }
}
