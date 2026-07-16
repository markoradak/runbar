import CoreGraphics
import SwiftUI

/// The Runbar brand mark: a 2×3 dot grid whose per-dot opacities come from
/// the brand assets (Design/brand/favicon.svg). Tintable so surfaces can
/// color it by status while keeping the recognizable pattern.
struct RunbarLogoMark: View {
    var tint: Color
    var dotSize: CGFloat = 3
    var spacing: CGFloat = 2.5

    /// Column-major opacities from the brand mark.
    static let opacities: [[Double]] = [
        [0.85, 0.7, 0.66],
        [1.0, 0.25, 0.4]
    ]

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0 ..< 2, id: \.self) { column in
                VStack(spacing: spacing) {
                    ForEach(0 ..< 3, id: \.self) { row in
                        Circle()
                            .fill(tint.opacity(Self.opacities[column][row]))
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
    }
}

/// Faithful, tintable rendering of Design/brand/icon-basic.svg: a 150-unit
/// tile (corner radius 44, 10-unit soft border band) with r=9 dots at the
/// asset's exact positions and opacities.
struct RunbarIconTile: View {
    var tint: Color
    var size: CGFloat = 34

    private static let dots: [(x: CGFloat, y: CGFloat, opacity: Double)] = [
        (59, 42, 0.85), (59, 75, 0.7), (59, 108, 0.66),
        (92, 42, 1.0), (92, 75, 0.25), (92, 108, 0.4)
    ]

    /// Scales the whole dot group around its center — smaller value pulls the
    /// dots in from the tile edges without changing their arrangement.
    private static let markScale: CGFloat = 0.85
    private static let markCenter = CGPoint(x: 75.5, y: 75)

    var body: some View {
        let scale = size / 150
        ZStack {
            RoundedRectangle(cornerRadius: 44 * scale, style: .continuous)
                .fill(tint.opacity(0.10))
            RoundedRectangle(cornerRadius: 44 * scale, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 13 * scale)
            ZStack {
                ForEach(Array(Self.dots.enumerated()), id: \.offset) { _, dot in
                    Circle()
                        .fill(tint.opacity(dot.opacity))
                        .frame(width: 22 * Self.markScale * scale, height: 22 * Self.markScale * scale)
                        .position(
                            x: (Self.markCenter.x + (dot.x - Self.markCenter.x) * Self.markScale) * scale,
                            y: (Self.markCenter.y + (dot.y - Self.markCenter.y) * Self.markScale) * scale
                        )
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// The "runbar" wordmark rendered from the brand vector outlines
/// (Design/brand/wordmark.svg), so it can be tinted like text.
struct RunbarWordmarkShape: Shape {
    static var aspectRatio: CGFloat {
        let bounds = combinedPath.boundingBoxOfPath
        guard bounds.height > 0 else { return 1 }
        return bounds.width / bounds.height
    }

    private nonisolated(unsafe) static let combinedPath: CGPath = {
        let combined = CGMutablePath()
        combined.addPath(SVGPathParser.cgPath(from: textPathData))
        combined.addPath(SVGPathParser.cgPath(from: registeredMarkPathData))
        return combined
    }()

    func path(in rect: CGRect) -> Path {
        let bounds = Self.combinedPath.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform(
            translationX: rect.minX + (rect.width - bounds.width * scale) / 2 - bounds.minX * scale,
            y: rect.minY + (rect.height - bounds.height * scale) / 2 - bounds.minY * scale
        )
        .scaledBy(x: scale, y: scale)
        return Path(Self.combinedPath).applying(transform)
    }

    private static let textPathData = "M6 116V50.36H31.8V70.16L27.6 64.52C29.6 59.4 32.8 55.56 37.2 53C41.6 50.44 46.88 49.16 53.04 49.16V73.16C51.84 73 50.76 72.88 49.8 72.8C48.92 72.72 48 72.68 47.04 72.68C42.96 72.68 39.6 73.76 36.96 75.92C34.4 78 33.12 81.64 33.12 86.84V116H6ZM85.6866 117.2C80.4866 117.2 75.7666 116.16 71.5266 114.08C67.3666 111.92 64.0866 108.6 61.6866 104.12C59.2866 99.56 58.0866 93.72 58.0866 86.6V50.36H85.2066V81.92C85.2066 86.56 85.9666 89.8 87.4866 91.64C89.0066 93.48 91.0866 94.4 93.7266 94.4C95.3266 94.4 96.8066 94 98.1666 93.2C99.6066 92.32 100.767 90.92 101.647 89C102.527 87 102.967 84.4 102.967 81.2V50.36H130.087V116H104.287V97.04L109.447 102.2C107.127 107.32 103.807 111.12 99.4866 113.6C95.2466 116 90.6466 117.2 85.6866 117.2ZM136.116 116V50.36H161.916V69.56L156.756 64.04C159.316 59.08 162.756 55.36 167.076 52.88C171.476 50.4 176.356 49.16 181.716 49.16C186.756 49.16 191.316 50.2 195.396 52.28C199.476 54.28 202.676 57.44 204.996 61.76C207.396 66.08 208.596 71.68 208.596 78.56V116H181.476V83.24C181.476 79.16 180.756 76.28 179.316 74.6C177.876 72.84 175.916 71.96 173.436 71.96C171.596 71.96 169.876 72.4 168.276 73.28C166.756 74.08 165.516 75.44 164.556 77.36C163.676 79.28 163.236 81.88 163.236 85.16V116H136.116ZM256.973 117.2C250.973 117.2 246.133 116 242.453 113.6C238.773 111.2 236.093 107.48 234.413 102.44C232.813 97.4 232.013 90.96 232.013 83.12C232.013 75.36 232.893 69 234.653 64.04C236.413 59 239.133 55.28 242.813 52.88C246.573 50.4 251.293 49.16 256.973 49.16C262.733 49.16 268.013 50.52 272.813 53.24C277.613 55.96 281.453 59.88 284.333 65C287.213 70.04 288.653 76.08 288.653 83.12C288.653 90.16 287.213 96.24 284.333 101.36C281.453 106.4 277.613 110.32 272.813 113.12C268.013 115.84 262.733 117.2 256.973 117.2ZM213.173 116V26.96H240.293V59.12L239.093 83.12L238.973 107.12V116H213.173ZM250.493 96.08C252.493 96.08 254.293 95.6 255.893 94.64C257.493 93.68 258.773 92.24 259.733 90.32C260.693 88.32 261.173 85.92 261.173 83.12C261.173 80.24 260.693 77.88 259.733 76.04C258.773 74.12 257.493 72.68 255.893 71.72C254.293 70.76 252.493 70.28 250.493 70.28C248.493 70.28 246.693 70.76 245.093 71.72C243.493 72.68 242.213 74.12 241.253 76.04C240.293 77.88 239.813 80.24 239.813 83.12C239.813 85.92 240.293 88.32 241.253 90.32C242.213 92.24 243.493 93.68 245.093 94.64C246.693 95.6 248.493 96.08 250.493 96.08ZM331.676 116V104.36L329.756 101.24V79.16C329.756 75.96 328.756 73.52 326.756 71.84C324.836 70.16 321.676 69.32 317.276 69.32C314.316 69.32 311.316 69.8 308.276 70.76C305.236 71.64 302.636 72.88 300.476 74.48L291.836 56.6C295.676 54.2 300.276 52.36 305.636 51.08C310.996 49.8 316.236 49.16 321.356 49.16C332.636 49.16 341.356 51.68 347.516 56.72C353.756 61.76 356.876 69.76 356.876 80.72V116H331.676ZM313.076 117.2C307.716 117.2 303.236 116.28 299.636 114.44C296.036 112.6 293.316 110.16 291.476 107.12C289.636 104 288.716 100.56 288.716 96.8C288.716 92.56 289.796 88.96 291.956 86C294.116 83.04 297.396 80.8 301.796 79.28C306.276 77.76 311.916 77 318.716 77H332.396V90.08H323.036C320.156 90.08 318.036 90.56 316.676 91.52C315.396 92.4 314.756 93.76 314.756 95.6C314.756 97.12 315.316 98.4 316.436 99.44C317.636 100.4 319.236 100.88 321.236 100.88C323.076 100.88 324.756 100.4 326.276 99.44C327.876 98.4 329.036 96.8 329.756 94.64L333.236 102.68C332.196 107.56 329.996 111.2 326.636 113.6C323.276 116 318.756 117.2 313.076 117.2ZM361.397 116V50.36H387.197V70.16L382.997 64.52C384.997 59.4 388.197 55.56 392.597 53C396.997 50.44 402.277 49.16 408.437 49.16V73.16C407.237 73 406.157 72.88 405.197 72.8C404.317 72.72 403.397 72.68 402.437 72.68C398.357 72.68 394.997 73.76 392.357 75.92C389.797 78 388.517 81.64 388.517 86.84V116H361.397Z"

    private static let registeredMarkPathData = "M407.395 118.074C406.162 118.074 405.019 117.852 403.967 117.408C402.915 116.964 401.995 116.348 401.205 115.559C400.416 114.753 399.8 113.825 399.356 112.773C398.929 111.721 398.715 110.586 398.715 109.37C398.715 108.153 398.937 107.019 399.381 105.967C399.825 104.915 400.441 103.995 401.23 103.205C402.019 102.4 402.94 101.775 403.992 101.332C405.06 100.888 406.211 100.666 407.444 100.666C408.677 100.666 409.819 100.888 410.871 101.332C411.94 101.759 412.86 102.367 413.633 103.156C414.422 103.945 415.03 104.866 415.458 105.918C415.901 106.953 416.123 108.088 416.123 109.321C416.123 110.553 415.901 111.704 415.458 112.773C415.014 113.825 414.389 114.753 413.584 115.559C412.795 116.348 411.874 116.964 410.822 117.408C409.77 117.852 408.627 118.074 407.395 118.074ZM408.973 114.005L406.704 110.504H410.304L412.573 114.005H408.973ZM407.395 115.904C408.315 115.904 409.162 115.74 409.934 115.411C410.723 115.066 411.405 114.597 411.981 114.005C412.556 113.414 413 112.723 413.312 111.934C413.641 111.129 413.805 110.258 413.805 109.321C413.805 108.384 413.649 107.521 413.337 106.732C413.025 105.942 412.589 105.26 412.03 104.685C411.471 104.093 410.797 103.641 410.008 103.329C409.236 103 408.381 102.836 407.444 102.836C406.507 102.836 405.644 103 404.855 103.329C404.082 103.658 403.408 104.118 402.833 104.71C402.258 105.301 401.814 106 401.501 106.805C401.189 107.595 401.033 108.449 401.033 109.37C401.033 110.29 401.189 111.153 401.501 111.959C401.814 112.748 402.249 113.438 402.808 114.03C403.384 114.622 404.058 115.082 404.83 115.411C405.619 115.74 406.474 115.904 407.395 115.904ZM403.326 114.005V104.734H407.74C409.121 104.734 410.189 105.047 410.945 105.671C411.718 106.296 412.104 107.134 412.104 108.186C412.104 109.337 411.718 110.2 410.945 110.775C410.189 111.351 409.121 111.638 407.74 111.638H406.877V114.005H403.326ZM406.877 109.197H407.518C407.847 109.197 408.101 109.107 408.282 108.926C408.463 108.745 408.553 108.499 408.553 108.186C408.553 107.874 408.463 107.627 408.282 107.447C408.101 107.266 407.847 107.175 407.518 107.175H406.877V109.197Z"
}
