import Testing
@testable import CodecCore

@Suite("FileReference")
struct FileReferenceTests {
    private let files: Set<String> = ["/p/README.md", "/p/Sources", "/p/Sources/main.swift", "/p/run.sh", "/home/notes.txt"]

    private func resolve(_ token: String, in directories: [String] = ["/p"]) -> String? {
        FileReference.resolve(token, in: directories, exists: files.contains)
    }

    @Test(arguments: [
        ("README.md", "/p/README.md"),
        ("Sources/", "/p/Sources"),
        ("./Sources/main.swift", "/p/Sources/main.swift"),
        ("Sources/main.swift:42:7", "/p/Sources/main.swift"),
        ("Sources/main.swift:42", "/p/Sources/main.swift"),
        ("run.sh*", "/p/run.sh"),
        ("/home/notes.txt", "/home/notes.txt"),
    ])
    func findsFilesRelativeToTheDirectory(token: String, expected: String) {
        #expect(resolve(token) == expected)
    }

    @Test func leavesWhatIsntAFileAlone() {
        #expect(resolve("total") == nil)
        #expect(resolve("https://p/README.md") == nil)
        #expect(resolve("") == nil)
        #expect(resolve("README.md", in: [""]) == nil)
    }

    @Test func looksInEachDirectoryInTurn() {
        #expect(resolve("main.swift", in: ["/p", "/p/Sources"]) == "/p/Sources/main.swift")
        #expect(resolve("main.swift") == nil)
    }

    @Test func aCommandsDirectoriesAreWhereItRanThenTheFoldersItWasGiven() {
        let folders: Set<String> = ["/p", "/p/Sources", "/p/Tests", "/etc"]
        let directories = FileReference.directories(command: "ls -la Sources 'Tests' /etc README.md ../p/Sources",
                                                    in: "/p", isDirectory: folders.contains)
        #expect(directories == ["/p", "/p/Sources", "/p/Tests", "/etc"])
        #expect(FileReference.directories(command: "ls Sources; ls Tests && cd /etc", in: "/p",
                                          isDirectory: folders.contains) == ["/p", "/p/Sources", "/p/Tests", "/etc"])
        #expect(FileReference.directories(command: "", in: "/p", isDirectory: folders.contains) == ["/p"])
        #expect(FileReference.directories(command: "ls", in: "", isDirectory: folders.contains).isEmpty)
    }
}
