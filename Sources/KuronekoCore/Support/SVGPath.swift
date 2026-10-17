import Foundation

/// The commands of an SVG path written only with absolute M, L, C and Z, as
/// the cat of the icons (Support/kuroneko-cat.svg) is.
public enum SVGPath {
    public enum Command: Equatable, Sendable {
        case move(x: Double, y: Double)
        case line(x: Double, y: Double)
        case curve(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
        case close
    }

    /// Nil for anything else: relative commands, arcs, a missing number.
    public static func parse(_ d: String) -> [Command]? {
        let tokens = d.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline })
        var commands: [Command] = []
        var index = 0
        func numbers(_ count: Int) -> [Double]? {
            guard index + count <= tokens.count else { return nil }
            let values = tokens[index..<index + count].compactMap { Double($0) }
            guard values.count == count else { return nil }
            index += count
            return values
        }
        while index < tokens.count {
            let letter = tokens[index]
            index += 1
            switch letter {
            case "M":
                guard let n = numbers(2) else { return nil }
                commands.append(.move(x: n[0], y: n[1]))
            case "L":
                guard let n = numbers(2) else { return nil }
                commands.append(.line(x: n[0], y: n[1]))
            case "C":
                guard let n = numbers(6) else { return nil }
                commands.append(.curve(x1: n[0], y1: n[1], x2: n[2], y2: n[3], x: n[4], y: n[5]))
            case "Z":
                commands.append(.close)
            default:
                return nil
            }
        }
        return commands
    }
}

/// Kuroneko's cat, the head, as in Support/kuroneko-cat.svg (a test keeps
/// the two the same): the menu bar and the Dock draw it.
public enum CatShape {
    public static let width = 93.86
    public static let height = 100.0
    public static let path = "M 9.28 0.52 C 6.01 1.57 3.40 12.81 3.40 25.75 C 3.40 30.98 3.66 33.86 4.44 39.08 L 4.71 41.44 L 4.44 41.83 C 3.27 43.66 3.14 46.54 4.05 49.80 L 4.44 50.72 L 3.40 52.68 C 1.31 56.99 0 61.44 0 64.84 C 0 70.20 3.40 76.47 9.67 82.75 C 23.01 95.69 45.88 100 65.75 93.20 C 76.08 89.67 84.84 82.88 89.80 74.38 C 93.86 67.45 93.73 61.44 89.41 52.68 L 88.50 50.72 L 88.76 49.80 C 89.67 46.54 89.54 43.66 88.37 41.83 L 88.10 41.44 L 88.37 39.08 C 90.07 28.10 89.67 16.34 87.45 7.45 C 86.01 2.48 84.58 0.39 82.35 0.39 C 76.73 0.39 63.40 12.55 56.47 24.18 C 56.08 24.84 55.82 25.36 55.69 25.36 C 55.69 25.36 55.03 25.23 54.25 25.10 C 51.63 24.71 49.67 24.44 46.41 24.44 C 43.14 24.44 41.18 24.71 38.69 25.10 C 37.78 25.23 37.12 25.36 37.12 25.36 C 36.99 25.36 36.73 24.84 36.34 24.18 C 31.63 16.47 23.53 7.58 16.99 3.14 C 13.59 0.92 10.98 0 9.28 0.52 Z"
}
