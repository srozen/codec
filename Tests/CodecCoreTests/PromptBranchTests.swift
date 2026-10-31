import Testing
@testable import CodecCore

@Suite("PromptBranch")
struct PromptBranchTests {
    private func found(_ branch: String, in line: String) -> String? {
        let characters = Array(line)
        return PromptBranch.range(of: branch, in: characters).map { String(characters[$0]) }
    }

    @Test(arguments: [
        ("  ~/code/codec   ⎇ main*  ", "main", "⎇ main*"),
        ("~/code/codec on feature/login via venv", "feature/login", "feature/login"),
        ("➜  codec git:(main) ✗", "main", "main"),
        ("[main] %", "main", "main"),
        ("~/main ⎇ main", "main", "⎇ main"),
        ("~/src/main on main", "main", "main"),
    ])
    func findsTheBranch(line: String, branch: String, expected: String) {
        #expect(found(branch, in: line) == expected)
    }

    @Test func ignoresTheNameInsideOtherWords() {
        #expect(found("main", in: "~/code/main % ") == nil)
        #expect(found("main", in: "mainline %") == nil)
        #expect(found("dev", in: "~/dev-tools %") == nil)
        #expect(found("", in: "anything") == nil)
        #expect(found("long-branch", in: "short") == nil)
    }
}
