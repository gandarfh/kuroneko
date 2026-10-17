import Foundation
import Testing
@testable import KuronekoCore

@Suite struct SVGPathTests {
    @Test func absoluteCommands() {
        #expect(SVGPath.parse("M 1 2 L 3.5 4 C 1 2 3 4 5 6 Z") == [
            .move(x: 1, y: 2),
            .line(x: 3.5, y: 4),
            .curve(x1: 1, y1: 2, x2: 3, y2: 4, x: 5, y: 6),
            .close,
        ])
    }

    @Test func refusesWhatItDoesNotDraw() {
        #expect(SVGPath.parse("m 1 2") == nil)
        #expect(SVGPath.parse("M 1") == nil)
        #expect(SVGPath.parse("C 1 2 3 4 5 x") == nil)
        #expect(SVGPath.parse("A 1 1 0 0 1 2 2") == nil)
    }

    /// The cat drawn by the app is the one in the SVG file.
    @Test func catMatchesTheFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/kuroneko-cat.svg")
        let svg = try String(contentsOf: file, encoding: .utf8)
        #expect(svg.contains("d=\"\(CatShape.path)\""))
        #expect(svg.contains("viewBox=\"0 0 \(String(format: "%.2f", CatShape.width)) \(String(format: "%.2f", CatShape.height))\""))
        let commands = try #require(SVGPath.parse(CatShape.path))
        #expect(commands.first == .move(x: 9.28, y: 0.52))
        #expect(commands.last == .close)
    }
}
