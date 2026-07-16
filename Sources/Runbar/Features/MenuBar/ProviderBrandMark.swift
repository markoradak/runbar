import CoreGraphics
import SwiftUI

/// Official brand marks for execution providers, rendered from embedded SVG
/// path data (simple-icons, 24×24 view box) so menu rows show real logos
/// instead of SF Symbol stand-ins.
enum ProviderBrandMark: Hashable {
    case github
    case vercel
    case cloudflare

    static let viewBoxEdge: CGFloat = 24

    var brandColor: Color {
        switch self {
        case .github, .vercel: Color.primary.opacity(0.88)
        case .cloudflare: Color(red: 0.965, green: 0.510, blue: 0.122) // #F6821F
        }
    }

    var cgPath: CGPath { Self.paths[self] ?? CGMutablePath() }

    private nonisolated(unsafe) static let paths: [ProviderBrandMark: CGPath] = [
        .github: SVGPathParser.cgPath(from: githubPathData),
        .vercel: SVGPathParser.cgPath(from: vercelPathData),
        .cloudflare: SVGPathParser.cgPath(from: cloudflarePathData)
    ]

    private static let githubPathData = """
        M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 \
        0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 \
        1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 \
        0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 \
        2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 \
        0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12
        """

    private static let vercelPathData = "m12 1.608 12 20.784H0Z"

    private static let cloudflarePathData = """
        M16.5088 16.8447c.1475-.5068.0908-.9707-.1553-1.3154-.2246-.3164-.6045-.499-1.0615-.5205l-8.6592-.1123\
        a.1559.1559 0 0 1-.1333-.0713c-.0283-.042-.0351-.0986-.021-.1553.0278-.084.1123-.1484.2036-.1562l8.7359-.1123\
        c1.0351-.0489 2.1601-.8868 2.5537-1.9136l.499-1.3013c.0215-.0561.0293-.1128.0147-.168-.5625-2.5463-2.835-4.4453-5.5499-4.4453\
        -2.5039 0-4.6284 1.6177-5.3876 3.8614-.4927-.3658-1.1187-.5625-1.794-.499-1.2026.119-2.1665 1.083-2.2861 2.2856\
        -.0283.31-.0069.6128.0635.894C1.5683 13.171 0 14.7754 0 16.752c0 .1748.0142.3515.0352.5273.0141.083.0844.1475.1689.1475\
        h15.9814c.0909 0 .1758-.0645.2032-.1553l.12-.4268zm2.7568-5.5634c-.0771 0-.1611 0-.2383.0112-.0566 0-.1054.0415-.127.0976\
        l-.3378 1.1744c-.1475.5068-.0918.9707.1543 1.3164.2256.3164.6055.498 1.0625.5195l1.8437.1133c.0557 0 .1055.0263.1329.0703\
        .0283.043.0351.1074.0214.1562-.0283.084-.1132.1485-.204.1553l-1.921.1123c-1.041.0488-2.1582.8867-2.5527 1.914l-.1406.3585\
        c-.0283.0713.0215.1416.0986.1416h6.5977c.0771 0 .1474-.0489.169-.126.1122-.4082.1757-.837.1757-1.2803 0-2.6025-2.125-4.727-4.7344-4.727
        """
}

extension ExecutionProvider {
    var brandMark: ProviderBrandMark {
        switch self {
        case .githubActions: .github
        case .vercel: .vercel
        case .cloudflarePages: .cloudflare
        }
    }
}

/// Fits a brand mark's path into the proposed rect, preserving aspect ratio.
struct ProviderBrandMarkShape: Shape {
    let mark: ProviderBrandMark

    func path(in rect: CGRect) -> Path {
        let edge = ProviderBrandMark.viewBoxEdge
        let scale = min(rect.width, rect.height) / edge
        let transform = CGAffineTransform(
            translationX: rect.minX + (rect.width - edge * scale) / 2,
            y: rect.minY + (rect.height - edge * scale) / 2
        )
        .scaledBy(x: scale, y: scale)
        return Path(mark.cgPath).applying(transform)
    }
}

/// Rounded "app tile" wrapper used across menu rows.
struct ProviderIconTile: View {
    let provider: ExecutionProvider
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.primary.opacity(0.055))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            ProviderBrandMarkShape(mark: provider.brandMark)
                .fill(provider.brandMark.brandColor)
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}

/// Minimal SVG path-data parser covering the commands used by the embedded
/// brand marks: M/L/H/V/C/S/Q/T/Z in absolute and relative form. Elliptical
/// arcs (A/a) are flattened to straight lines — the bundled marks only use
/// hairline-radius arcs where the difference is sub-pixel.
enum SVGPathParser {
    static func cgPath(from data: String) -> CGPath {
        var scanner = TokenScanner(data)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character = " "

        while true {
            if let next = scanner.nextCommand() {
                command = next
            } else if scanner.isAtEnd() || command == " " {
                break
            }

            let isRelative = command.isLowercase
            func resolve(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(command.lowercased()) {
            case "m":
                guard let n = scanner.numbers(2) else { return path }
                current = resolve(n[0], n[1])
                subpathStart = current
                path.move(to: current)
                command = isRelative ? "l" : "L"
                lastCubicControl = nil
                lastQuadControl = nil
            case "l":
                guard let n = scanner.numbers(2) else { return path }
                current = resolve(n[0], n[1])
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "h":
                guard let n = scanner.numbers(1) else { return path }
                current = CGPoint(x: isRelative ? current.x + n[0] : n[0], y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "v":
                guard let n = scanner.numbers(1) else { return path }
                current = CGPoint(x: current.x, y: isRelative ? current.y + n[0] : n[0])
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "c":
                guard let n = scanner.numbers(6) else { return path }
                let control1 = resolve(n[0], n[1])
                let control2 = resolve(n[2], n[3])
                current = resolve(n[4], n[5])
                path.addCurve(to: current, control1: control1, control2: control2)
                lastCubicControl = control2
                lastQuadControl = nil
            case "s":
                guard let n = scanner.numbers(4) else { return path }
                let control1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let control2 = resolve(n[0], n[1])
                current = resolve(n[2], n[3])
                path.addCurve(to: current, control1: control1, control2: control2)
                lastCubicControl = control2
                lastQuadControl = nil
            case "q":
                guard let n = scanner.numbers(4) else { return path }
                let control = resolve(n[0], n[1])
                current = resolve(n[2], n[3])
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control
                lastCubicControl = nil
            case "t":
                guard let n = scanner.numbers(2) else { return path }
                let control = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                current = resolve(n[0], n[1])
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control
                lastCubicControl = nil
            case "a":
                guard let n = scanner.numbers(7) else { return path }
                current = resolve(n[5], n[6])
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
                command = " "
            default:
                return path
            }
        }
        return path
    }

    private struct TokenScanner {
        private let chars: [Character]
        private var index = 0

        init(_ string: String) {
            chars = Array(string)
        }

        mutating func isAtEnd() -> Bool {
            skipSeparators()
            return index >= chars.count
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isLetter else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        mutating func numbers(_ count: Int) -> [CGFloat]? {
            var values: [CGFloat] = []
            values.reserveCapacity(count)
            for _ in 0 ..< count {
                guard let value = nextNumber() else { return nil }
                values.append(value)
            }
            return values
        }

        private mutating func nextNumber() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }
            var text = ""
            var seenDot = false
            if chars[index] == "+" || chars[index] == "-" {
                text.append(chars[index])
                index += 1
            }
            loop: while index < chars.count {
                let character = chars[index]
                switch character {
                case "0" ... "9":
                    text.append(character)
                    index += 1
                case ".":
                    if seenDot { break loop }
                    seenDot = true
                    text.append(character)
                    index += 1
                case "e", "E":
                    text.append(character)
                    index += 1
                    if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                        text.append(chars[index])
                        index += 1
                    }
                default:
                    break loop
                }
            }
            return Double(text).map { CGFloat($0) }
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == "," || chars[index].isWhitespace {
                index += 1
            }
        }
    }
}
