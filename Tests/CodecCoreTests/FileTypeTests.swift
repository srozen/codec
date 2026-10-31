import Testing
@testable import CodecCore

@Suite("FileType")
struct FileTypeTests {
    @Test(arguments: [
        ("main.swift", FileType.swift), ("App.TSX", .typescript), ("index.mjs", .javascript), ("setup.py", .python),
        ("lib.rs", .rust), ("main.go", .go), ("util.h", .c), ("View.mm", .objectiveC), ("run.zsh", .shell),
        ("README.md", .readme), ("readme", .readme), ("CHANGELOG.md", .markdown), ("notes.md", .markdown),
        ("LICENSE", .license), ("License.txt", .license), ("Package.swift", .manifest), ("package.json", .manifest),
        ("Makefile", .manifest), ("Package.resolved", .lockfile), ("yarn.lock", .lockfile), ("Cargo.lock", .lockfile),
        (".env", .environment), (".env.local", .environment), ("prod.env", .environment), (".gitignore", .git),
        (".gitattributes", .git), ("Dockerfile", .docker), ("Dockerfile.dev", .docker), ("compose.yaml", .docker),
        ("config.yml", .yaml), ("Info.plist", .xml), ("tsconfig.json", .json), (".zshrc", .config), (".editorconfig", .config),
        ("icon.PNG", .image), ("logo.svg", .vector), ("codec_call.mp3", .audio), ("demo.mov", .video), ("Inter.woff2", .font),
        ("release.zip", .archive), ("libfoo.dylib", .binary), ("build.log", .log), ("data.csv", .csv), ("manual.pdf", .pdf),
        ("mystery", .other), ("file.unknownext", .other),
    ])
    func classifiesFiles(name: String, expected: FileType) {
        #expect(FileType.of(fileNamed: name) == expected)
    }

    @Test(arguments: [
        ("Sources", FolderType.source), ("src", .source), ("Tests", .tests), ("__tests__", .tests), ("docs", .docs),
        ("Assets", .assets), ("scripts", .scripts), (".github", .config), ("node_modules", .dependencies),
        (".build", .build), ("dist", .build), ("Codec", .plain),
    ])
    func classifiesFolders(name: String, expected: FolderType) {
        #expect(FolderType.of(folderNamed: name) == expected)
    }
}
