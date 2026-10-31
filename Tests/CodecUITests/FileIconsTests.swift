import Testing
import AppKit
import CodecCore
@testable import CodecUI

@Suite("File icons")
@MainActor
struct FileIconsTests {
    /// How many pixels an icon covers when drawn at 2x.
    private func coverage(_ image: NSImage) -> Int {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = FileIcons.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: FileIcons.size))
        NSGraphicsContext.restoreGraphicsState()
        var covered = 0
        for x in 0..<32 { for y in 0..<32 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { covered += 1 } }
        return covered
    }

    @Test func everyTypeHasAnIconInEveryTheme() {
        for theme in CodecTheme.all {
            for type in FileType.allCases {
                let image = FileIcons.image(for: type, theme: theme)
                #expect(image.size == FileIcons.size)
                #expect(coverage(image) > 150, "\(type) in \(theme.id)")
            }
            for folder in FolderType.allCases {
                #expect(coverage(FileIcons.image(for: folder, state: .closed, theme: theme)) > 150)
            }
        }
    }

    @Test func iconsAreMadeOncePerTheme() {
        #expect(FileIcons.image(for: .swift, theme: .codec) === FileIcons.image(for: .swift, theme: .codec))
        #expect(FileIcons.image(for: .swift, theme: .codec) !== FileIcons.image(for: .swift, theme: .daylight))
        #expect(FileIcons.image(for: .source, state: .open, theme: .codec) !== FileIcons.image(for: .source, state: .closed, theme: .codec))
    }

    @Test func typesInTheSameFamilyShareAMark() {
        #expect(FileIcons.mark(for: .swift) == .letters("SW"))
        #expect(FileIcons.mark(for: .shell) == .prompt)
        #expect(FileIcons.mark(for: .audio) == .bars)
        #expect(FileIcons.mark(for: .yaml) == FileIcons.mark(for: .toml))
    }
}
