import Testing
import Foundation
@testable import CodecCore

@Suite("Intel")
struct IntelTests {
    private let deploy = """
    ---
    title: Deploy a branch
    description: "Pushes it, then deploys: carefully"
    kind: script
    variables:
      - name: branch
        description: What to deploy
        default: main
      - name: env
        choices: [staging, "prod, eu"]
      - name: region
        choices:
          - us-east
          - eu-west
    ---

    Deploys from CI's last build.

    ```sh
    git push origin {{branch}} && ./deploy --env {{ env }} --region {{region}} --tag {{tag}}
    ```

    Then check the dashboard.
    """

    @Test func readsAScript() {
        let item = IntelItem.parse(deploy, fallbackTitle: "deploy")
        #expect(item.kind == .script)
        #expect(item.title == "Deploy a branch")
        #expect(item.description == "Pushes it, then deploys: carefully")
        #expect(item.variables == [
            IntelVariable(name: "branch", description: "What to deploy", defaultValue: "main"),
            IntelVariable(name: "env", choices: ["staging", "prod, eu"]),
            IntelVariable(name: "region", choices: ["us-east", "eu-west"]),
        ])
        #expect(item.command == "git push origin {{branch}} && ./deploy --env {{ env }} --region {{region}} --tag {{tag}}")
        // Blanks that aren't declared are plain text variables.
        #expect(item.allVariables.map(\.name) == ["branch", "env", "region", "tag"])
    }

    @Test func fillsInVariables() {
        let item = IntelItem.parse(deploy, fallbackTitle: "deploy")
        #expect(item.resolvedCommand(["env": "staging", "region": "eu-west", "tag": "v2"])
            == "git push origin main && ./deploy --env staging --region eu-west --tag v2")
        // Without a value, a variable takes its default, which may be empty.
        #expect(item.resolvedCommand([:]) == "git push origin main && ./deploy --env  --region  --tag ")
        #expect(IntelPlaceholders.fill("a {{x}} {{y}}", with: ["x": "1"]) == "a 1 {{y}}")
        #expect(IntelPlaceholders.names(in: "{{a}} {{b-c}} {{a}} {{ 9x }} {x}") == ["a", "b-c"])
    }

    @Test func writesWhatItReads() {
        let item = IntelItem.parse(deploy, fallbackTitle: "deploy")
        let again = IntelItem.parse(item.fileText, fallbackTitle: "other")
        #expect(again.variables == item.variables)
        #expect(again.command == item.command)
        // The file gains a final newline, and then stays the same.
        #expect(again.body == item.body + "\n")
        #expect(IntelItem.parse(again.fileText, fallbackTitle: "other") == again)
        #expect(item.fileText.hasPrefix("---\ntitle: Deploy a branch\ndescription: \"Pushes it, then deploys: carefully\"\nkind: script\n"))
    }

    @Test func quotesValuesThatWouldReadAsSomethingElse() {
        var item = IntelItem.script(title: "yes", description: "# not a comment", command: "echo {{port}}",
                                    variables: [IntelVariable(name: "port", defaultValue: "8080", choices: ["a]b", "c,d", "- e"])])
        item.title = "true"
        let again = IntelItem.parse(item.fileText, fallbackTitle: "x")
        #expect(again.title == "true")
        #expect(again.description == "# not a comment")
        #expect(again.variables == item.variables)
        #expect(again.command == "echo {{port}}")
    }

    @Test func changesTheCommandInPlace() {
        var item = IntelItem.parse(deploy, fallbackTitle: "deploy")
        item.command = "make deploy"
        #expect(item.body.contains("Deploys from CI's last build.\n\n```sh\nmake deploy\n```\n\nThen check the dashboard."))

        var plain = IntelItem(kind: .script, title: "x", body: "ls -la\n")
        #expect(plain.command == "ls -la")
        plain.command = "ls"
        #expect(plain.body == "```sh\nls\n```\n")
        #expect(IntelItem.script(title: "t", command: "echo hi").command == "echo hi")
    }

    @Test func aFileWithoutAHeaderIsADocument() {
        let item = IntelItem.parse("# Notes\n\nSome text.", fallbackTitle: "notes")
        #expect(item.kind == .doc)
        #expect(item.title == "notes")
        #expect(item.body == "# Notes\n\nSome text.")
        let unclosed = IntelItem.parse("---\ntitle: x\n", fallbackTitle: "f")
        #expect(unclosed.kind == .doc && unclosed.title == "f")
    }

    @Test func namesFilesAfterTitles() {
        #expect(IntelItem.fileName(for: "Deploy a Branch!") == "deploy-a-branch.md")
        #expect(IntelItem.fileName(for: "Café über alles") == "cafe-uber-alles.md")
        #expect(IntelItem.fileName(for: "???") == "untitled.md")
        #expect(IntelPlaceholders.name(from: "Target branch") == "target_branch")
        #expect(IntelPlaceholders.name(from: "2fa") == "_2fa")
    }

    @Test func suggestsVariablesFromACommand() {
        let command = #"git push origin feature/login && curl -X POST https://api.test/v1 -d "hello there" --port=8080 -o out.json ./build/app"#
        let candidates = IntelSuggestions.candidates(in: command, branch: "feature/login")
        // Named after their flag when it says more than a letter does.
        #expect(candidates.map(\.name) == ["branch", "url", "message", "port", "file", "path"])
        #expect(candidates.map(\.value) == ["feature/login", "https://api.test/v1", "hello there", "8080", "out.json", "./build/app"])
        let characters = Array(command)
        for candidate in candidates {
            #expect(String(characters[candidate.range]) == candidate.value)
        }
        // The command's own name never is one, nor are flags, words or existing blanks.
        #expect(IntelSuggestions.candidates(in: "./run.sh --verbose fast {{x}} | ./tool").isEmpty)
        #expect(IntelSuggestions.candidates(in: "cp a.txt b.txt").map(\.name) == ["file", "file_2"])
    }

    @Test func rendersRunLinksOnShellBlocks() {
        let markdown = "---\ntitle: x\n---\n# Setup\n\n```sh\nmake\n```\n\n```swift\nlet a = 1\n```\n\n- step\n\n  ```bash\n  make test\n  ```\n"
        let plain = MarkdownRenderer().render(markdown)
        #expect(plain.shellBlocks == ["make", "make test"])
        #expect(!plain.html.contains("codec-run"))
        #expect(!plain.html.contains("title: x"))
        let runnable = MarkdownRenderer(runnableShellBlocks: true).html(from: markdown)
        #expect(runnable.contains("href=\"codec-run:run/0\""))
        #expect(runnable.contains("href=\"codec-run:insert/1\""))
        #expect(!runnable.contains("codec-run:run/2"))
    }
}
