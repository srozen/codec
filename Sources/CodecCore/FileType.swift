import Foundation

/// What kind of file a name suggests, for the file tree's icons.
public enum FileType: String, CaseIterable, Sendable {
    // Languages
    case swift, javascript, typescript, python, ruby, go, rust, c, cpp, objectiveC, java, kotlin, csharp, php, lua, sql
    case html, css, shell
    // Documents and data
    case markdown, text, pdf, json, yaml, toml, xml, config, log, csv
    // Media
    case image, vector, audio, video, font
    // Project files
    case manifest, lockfile, docker, git, environment, license, readme, archive, binary
    case other

    /// The type of a file named `name`.
    public static func of(fileNamed name: String) -> FileType {
        let lower = name.lowercased()
        if let type = byName[lower] { return type }
        if lower.hasPrefix("readme") { return .readme }
        if lower.hasPrefix("license") || lower.hasPrefix("licence") || lower.hasPrefix("copying") { return .license }
        if lower.hasPrefix(".env") || lower.hasSuffix(".env") { return .environment }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return .docker }
        if lower.hasPrefix(".git") { return .git }
        let ext = (lower as NSString).pathExtension
        return byExtension[ext] ?? (lower.hasPrefix(".") && lower.hasSuffix("rc") ? .config : .other)
    }

    private static let byName: [String: FileType] = [
        "package.swift": .manifest, "package.json": .manifest, "cargo.toml": .manifest, "go.mod": .manifest,
        "gemfile": .manifest, "podfile": .manifest, "pyproject.toml": .manifest, "requirements.txt": .manifest,
        "build.gradle": .manifest, "pom.xml": .manifest, "makefile": .manifest, "cmakelists.txt": .manifest,
        "package.resolved": .lockfile, "package-lock.json": .lockfile, "yarn.lock": .lockfile, "pnpm-lock.yaml": .lockfile,
        "cargo.lock": .lockfile, "gemfile.lock": .lockfile, "podfile.lock": .lockfile, "go.sum": .lockfile, "poetry.lock": .lockfile,
        "docker-compose.yml": .docker, "docker-compose.yaml": .docker, "compose.yml": .docker, "compose.yaml": .docker,
        ".dockerignore": .docker, ".editorconfig": .config, ".swiftlint.yml": .config, ".prettierrc": .config,
        "changelog.md": .markdown,
    ]

    private static let byExtension: [String: FileType] = {
        var map: [String: FileType] = [:]
        let groups: [(FileType, [String])] = [
            (.swift, ["swift"]), (.javascript, ["js", "mjs", "cjs", "jsx"]), (.typescript, ["ts", "tsx", "mts", "cts"]),
            (.python, ["py", "pyi", "ipynb"]), (.ruby, ["rb", "rake", "gemspec"]), (.go, ["go"]), (.rust, ["rs"]),
            (.c, ["c", "h"]), (.cpp, ["cpp", "cc", "cxx", "hpp", "hh", "hxx"]), (.objectiveC, ["m", "mm"]),
            (.java, ["java"]), (.kotlin, ["kt", "kts"]), (.csharp, ["cs"]), (.php, ["php"]), (.lua, ["lua"]), (.sql, ["sql"]),
            (.html, ["html", "htm", "xhtml", "vue", "svelte"]), (.css, ["css", "scss", "sass", "less"]),
            (.shell, ["sh", "zsh", "bash", "fish", "command", "ps1"]),
            (.markdown, ["md", "markdown", "mdx", "rst"]), (.text, ["txt", "rtf"]), (.pdf, ["pdf"]),
            (.json, ["json", "jsonc", "json5", "geojson"]), (.yaml, ["yml", "yaml"]), (.toml, ["toml"]),
            (.xml, ["xml", "plist", "xib", "storyboard", "entitlements", "xcconfig"]), (.config, ["ini", "conf", "cfg", "properties"]),
            (.log, ["log"]), (.csv, ["csv", "tsv"]),
            (.image, ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif", "icns", "ico"]), (.vector, ["svg", "eps", "ai"]),
            (.audio, ["mp3", "wav", "aiff", "aif", "m4a", "flac", "ogg", "caf"]), (.video, ["mp4", "mov", "m4v", "webm", "avi", "mkv"]),
            (.font, ["ttf", "otf", "woff", "woff2"]),
            (.lockfile, ["lock", "resolved"]),
            (.archive, ["zip", "gz", "tgz", "tar", "xz", "bz2", "7z", "rar", "dmg", "pkg"]),
            (.binary, ["o", "a", "dylib", "so", "dll", "exe", "bin", "wasm", "class", "jar"]),
        ]
        for (type, extensions) in groups { for ext in extensions { map[ext] = type } }
        return map
    }()
}

/// What kind of folder a name suggests.
public enum FolderType: String, CaseIterable, Sendable {
    case plain, source, tests, docs, assets, scripts, config, dependencies, build

    public static func of(folderNamed name: String) -> FolderType {
        switch name.lowercased() {
        case "sources", "source", "src", "lib", "libs", "app", "apps", "pkg", "internal", "cmd": .source
        case "tests", "test", "spec", "specs", "__tests__", "e2e", "uitests": .tests
        case "docs", "doc", "documentation", "guides": .docs
        case "assets", "images", "img", "icons", "resources", "media", "static", "public", "fonts", "sounds": .assets
        case "scripts", "script", "bin", "tools", "tasks": .scripts
        case ".github", ".vscode", ".idea", ".config", ".circleci", ".gitlab", ".husky", ".swiftpm", "config", "configs": .config
        case "node_modules", "pods", "vendor", "packages", ".venv", "venv", "carthage", "checkouts": .dependencies
        case "build", ".build", "dist", "out", "target", "deriveddata", "__pycache__", "coverage", ".next": .build
        default: .plain
        }
    }
}
