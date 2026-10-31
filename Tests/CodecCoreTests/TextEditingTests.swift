import Testing
import Foundation
@testable import CodecCore

@Suite("TextEditing")
struct TextEditingTests {
    @Test func readsTextBinaryAndOtherEncodings() {
        #expect(TextFile.read(Data("héllo\n".utf8)) == .text("héllo\n"))
        #expect(TextFile.read(Data([0xEF, 0xBB, 0xBF]) + Data("bom".utf8)) == .text("bom"))
        #expect(TextFile.read(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == .binary)
        #expect(TextFile.read(Data([0x63, 0x61, 0x66, 0xE9])) == .otherEncoding("café"))
        #expect(TextFile.read(Data(count: TextFile.sizeLimit + 1)) == .tooLarge(TextFile.sizeLimit + 1))
    }

    @Test func detectsIndentation() {
        #expect(Indentation.detect(in: "a {\n  b {\n    c\n  }\n}") == .spaces(2))
        #expect(Indentation.detect(in: "a {\n    b\n        c\n}") == .spaces(4))
        #expect(Indentation.detect(in: "a {\n\tb\n\t\tc\n}") == .tabs)
        #expect(Indentation.detect(in: "no indentation") == .spaces(4))
        #expect(Indentation.tabs.unit == "\t")
    }

    @Test func returnKeepsAndDeepensIndentation() {
        #expect(TextEditing.newline(after: "    let x = 1", indentation: .spaces(4), language: .swift) == "\n    ")
        #expect(TextEditing.newline(after: "  func f() {", indentation: .spaces(2), language: .swift) == "\n    ")
        #expect(TextEditing.newline(after: "def f():", indentation: .spaces(4), language: .python) == "\n    ")
        #expect(TextEditing.newline(after: "label:", indentation: .spaces(4), language: .swift) == "\n")
        #expect(TextEditing.newline(after: "\tif x {", indentation: .tabs, language: .go) == "\n\t\t")
    }

    @Test func togglesComments() {
        let code = ["    let a = 1", "", "      let b = 2"]
        let commented = TextEditing.toggleComment(code, prefix: "//")
        #expect(commented == ["    // let a = 1", "", "    //   let b = 2"])
        #expect(TextEditing.toggleComment(commented, prefix: "//") == code)
        #expect(TextEditing.toggleComment(["# x", "y"], prefix: "#") == ["# # x", "# y"])
        #expect(TextEditing.toggleComment(["", " "], prefix: "#") == ["", " "])
    }

    @Test func outdents() {
        #expect(TextEditing.outdent("      x", indentation: .spaces(4)) == "  x")
        #expect(TextEditing.outdent("  x", indentation: .spaces(4)) == "x")
        #expect(TextEditing.outdent("\t\tx", indentation: .tabs) == "\tx")
    }
}
