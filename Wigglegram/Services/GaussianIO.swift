import Foundation
import simd

/// Write a `GaussianCloud` out as a 3DGS-style binary PLY.
///
/// Ported from SharpSplat's GaussianIO — trimmed to the write side since
/// the viewer reads via MetalSplatter's `AutodetectSceneReader`. Kept the
/// full 3DGS property set (`f_dc_*`, `scale_*` in log space, `rot_*`,
/// `opacity` as pre-sigmoid logit) so the PLY is readable by any
/// 3DGS tool.
enum GaussianIO {
    static func savePLY(cloud: GaussianCloud, to url: URL) throws {
        let n = cloud.count
        var data = Data()

        func appendStr(_ s: String) { data.append(s.data(using: .ascii)!) }
        func appendF32(_ v: Float) { var val = v; data.append(Data(bytes: &val, count: 4)) }

        appendStr("ply\n")
        appendStr("format binary_little_endian 1.0\n")
        appendStr("element vertex \(n)\n")
        for prop in [
            "x", "y", "z",
            "f_dc_0", "f_dc_1", "f_dc_2",
            "opacity",
            "scale_0", "scale_1", "scale_2",
            "rot_0", "rot_1", "rot_2", "rot_3",
        ] {
            appendStr("property float \(prop)\n")
        }
        appendStr("end_header\n")

        let shCoeff = sqrt(1.0 / (4.0 * Float.pi))
        for i in 0..<n {
            let p = cloud.positions[i]
            appendF32(p.x); appendF32(p.y); appendF32(p.z)

            let c = cloud.colors[i]
            for ch in [c.x, c.y, c.z] {
                let srgb = linearToSRGB(ch)
                // DC SH coefficient convention used by 3DGS trainers.
                appendF32((srgb - 0.5) / shCoeff)
            }

            appendF32(inverseSigmoid(cloud.opacities[i]))

            let s = cloud.scales[i]
            // 3DGS stores scales as log(sigma) so negatives compress sharp
            // gaussians and the loss stays well-behaved.
            appendF32(log(max(s.x, 1e-10)))
            appendF32(log(max(s.y, 1e-10)))
            appendF32(log(max(s.z, 1e-10)))

            let q = cloud.rotations[i]
            appendF32(q.real); appendF32(q.imag.x); appendF32(q.imag.y); appendF32(q.imag.z)
        }

        try data.write(to: url)
    }

    private static func linearToSRGB(_ v: Float) -> Float {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private static func inverseSigmoid(_ x: Float) -> Float {
        let c = min(max(x, 1e-6), 1.0 - 1e-6)
        return log(c / (1.0 - c))
    }
}
