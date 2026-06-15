import AppKit
import QuartzCore

// Faithful port of the approved mockup #24 ("I think you did it"):
// .claude/plans/widget-mockups/24_mic_release_confident_vs_unsure.html
//
// An 18x18 pixel EQ filling a near-black rounded square (#060607). Bars rise per
// column in a red->blue->purple spectrum with the LEADING pixel always purple.
// NOISE drives bar MOTION (organized vs disorganized); CONFIDENCE drives
// INTEGRITY (desaturate + flicker + missing pixels) - fully decoupled. The mic
// glyph is a thin stroke drawn OVER the pixels, colored white->red->gray by
// confidence, with breathe/wobble. Finalize = snap pulse; a confidence climb =
// heel bloom (recovery); release = a white lock ring that fills around then
// powers down to black (confident = white + bloom; unsure = muted gray, partial,
// stutter, no white).
//
// All geometry is authored in the mockup's 24x24 SVG space and mapped to view
// pixels by P(x,y) (y flipped: SVG is y-down, NSView is y-up). Signals come from
// WidgetSignals (energy = RMS, confidence = recognizer proxy); noise is a
// short-term energy-jitter estimate (no separate acoustic-noise signal yet).
final class LEDMicView: NSView {
    // palette (0..255), straight from the mockup
    private let RED = [255.0, 59, 48], BLUE = [46.0, 123, 255], PUR = [122.0, 63, 240]
    private let GRAY = [120.0, 120, 130], REC = [255.0, 46, 58], WHITE = [255.0, 255, 255], MUTE = [150.0, 150, 162]
    private let X0 = 1.0, Y0 = 1.0, WD = 22.0, HT = 22.0
    private let pitch = 1.2, bp = 0.52, burn = 0.18

    private var cols = 18, rows = 18
    private var iw = [Double](), ipa = [Double](), hgt = [Double]()      // per column
    private var ph = [[Double]](), fr = [[Double]](), rm = [[Double]](), gp = [[Double]]()  // per cell [col][b]

    // smoothed + target signals
    private var e = 0.0, c = 1.0, nz = 0.12
    private var E = 0.0, Ctar = 1.0, Ntar = 0.12
    private var prevCtar = 1.0, ePrev = 0.0

    // event clocks (seconds, CACurrentMediaTime)
    private var tNow = 0.0
    private var snapStart = -9.0, recStart = -9.0, relStart = -9.0
    private var lockStr = 0.0, recBonus = 0.0
    private var releasing = false, idle = true
    private var lastSnapSeen = 0.0

    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func rnd() -> Double { Double.random(in: 0 ..< 1) }
    private func cl(_ v: Double, _ a: Double, _ b: Double) -> Double { v < a ? a : (v > b ? b : v) }
    private func Lc(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
        [a[0] + (b[0]-a[0])*t, a[1] + (b[1]-a[1])*t, a[2] + (b[2]-a[2])*t]
    }
    private func spectrum(_ f: Double) -> [Double] {
        f <= bp ? Lc(RED, BLUE, f/bp) : Lc(BLUE, PUR, (f-bp)/(1-bp))
    }
    private func flick(_ t: Double, _ phc: Double, _ depth: Double) -> Double {
        if depth <= 0.002 { return 1 }
        let waver = depth * 0.22 * (0.5 + 0.5*sin(t*17 + phc))
        let stut = (sin(t*30 + phc*2.3) > (1 - depth*0.55)) ? depth*0.6 : 0
        return max(0.14, 1 - waver - stut)
    }

    private func build() {
        cols = Int((WD/pitch).rounded(.down))   // 18
        rows = Int((HT/pitch).rounded(.down))   // 18
        iw = []; ipa = []; hgt = []; ph = []; fr = []; rm = []; gp = []
        for _ in 0..<cols {
            iw.append(1.4 + rnd()*2.4); ipa.append(rnd()*6.28); hgt.append(0)
            var p = [Double](), f = [Double](), r = [Double](), g = [Double]()
            for _ in 0..<rows { p.append(rnd()*6.28); f.append(6 + rnd()*9); r.append(rnd()); g.append(rnd()*6.28) }
            ph.append(p); fr.append(f); rm.append(r); gp.append(g)
        }
    }

    // Map raw RMS (~0.005..0.3 speech) to the mockup's 0..1 energy.
    private func energyCurve(_ rms: Float) -> Double {
        let r = Double(rms)
        if r < 0.004 { return 0 }
        return min(1, sqrt(r) * 2.2)
    }

    // MARK: - Lifecycle (RecordingOverlay show/hide)

    func beginListening() {
        idle = false; releasing = false
        prevCtar = 1; for i in 0..<hgt.count { hgt[i] = 0 }
        startTimer()
    }

    func endListening() {
        let conf = Double(WidgetSignals.shared.snapshot().releaseConfidence)
        doRelease(conf)
        startTimer()
    }

    private func doRelease(_ conf: Double) {
        idle = false
        Ctar = conf; c = conf
        recBonus = (conf > 0.6 && tNow - recStart < 2.2) ? 0.3 : 0
        lockStr = cl(conf + recBonus, 0, 1)
        relStart = tNow
        releasing = true
    }

    private func startTimer() {
        if timer != nil { return }
        let t = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    // MARK: - Per-frame state update

    private func tick() {
        let s = WidgetSignals.shared.snapshot()
        tNow = CACurrentMediaTime()
        let t = tNow

        if !releasing {
            E = energyCurve(s.energy)
            Ctar = Double(s.confidence)
        }
        // noise estimate from energy jitter (no acoustic-noise signal yet)
        let jitter = abs(E - ePrev); ePrev = E
        Ntar += (cl(jitter * 7, 0.05, 0.9) - Ntar) * 0.15

        // finalize snap (real event from the recognizer)
        if s.lastSnapAt != lastSnapSeen && s.lastSnapAt > 0 && !idle && !releasing {
            snapStart = t; lastSnapSeen = s.lastSnapAt
        }
        // confidence climbing sharply -> heel bloom (recovery)
        if !releasing, Ctar - prevCtar > 0.18 { recStart = t }
        prevCtar = Ctar

        e += (E - e) * 0.18
        c += (Ctar - c) * 0.08
        nz += (Ntar - nz) * 0.1

        let reP = (t - relStart) / 1.9
        let inRel = releasing && reP >= 0 && reP < 1
        if releasing, reP >= 1 { releasing = false; idle = true }

        for col in 0..<cols {
            let organized = sin(t * 2 * .pi * 1.3 + Double(col)*0.62)
            let disorg = sin(t*iw[col] + ipa[col])*0.7 + sin(t*iw[col]*2.3 + Double(col)*1.7)*0.3
            let m = (1-nz)*organized + nz*disorg
            let swing = (0.5 + 0.5*m) * (0.72 + nz*0.55)
            let target = cl(e * (0.42 + 0.6*swing), 0, 1)
            hgt[col] += (target - hgt[col]) * ((inRel || idle) ? 0 : (0.16 + 0.5*nz))
        }

        needsDisplay = true
        if idle { stopTimer() }   // settle on a static black frame
    }

    // MARK: - Draw

    private func mkColor(_ rgb: [Double], _ a: Double) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb[0]/255), green: CGFloat(rgb[1]/255), blue: CGFloat(rgb[2]/255), alpha: CGFloat(cl(a, 0, 1)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = tNow

        // 24x24 SVG space -> centered square in view pixels, y flipped.
        let S = min(bounds.width, bounds.height) / 24.0
        let ox = (bounds.width - 24*S) / 2, oy = (bounds.height - 24*S) / 2
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + CGFloat(x)*S, y: oy + CGFloat(24 - y)*S) }
        // a rect authored in SVG coords (x,y = top-left, y-down) -> view CGRect
        func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: ox + CGFloat(x)*S, y: oy + CGFloat(24 - (y+h))*S, width: CGFloat(w)*S, height: CGFloat(h)*S)
        }

        // derived timing (mirror the mockup's tick)
        let rP = (t - recStart) / 0.6
        let rec = (rP >= 0 && rP < 1) ? sin(rP * .pi) : 0
        let reP = (t - relStart) / 1.9
        let inRel = releasing && reP >= 0 && reP < 1
        let pwr = releasing ? (reP < 0.4 ? 1.0 : cl(1 - (reP-0.4)/0.5, 0, 1)) : (idle ? 0.0 : 1.0)
        let snP = (t - snapStart) / 0.13
        let inSnap = snP >= 0 && snP < 1 && !idle && !releasing
        var gap = cl(1 - c, 0, 1); if inSnap { gap *= (1 - snP) }; gap *= (1 - rec)
        let dsat = gap * 0.55, whiteMix = rec * 0.42
        let fdepth = cl((gap - 0.12)/0.7, 0, 1)
        let missCh = gap > 0.5 ? (gap - 0.5)*0.5 : 0

        // tile background #060607, clip pixels to it
        let bg = R(0.6, 0.6, 22.8, 22.8)
        let bgPath = CGPath(roundedRect: bg, cornerWidth: 5*S, cornerHeight: 5*S, transform: nil)
        ctx.addPath(bgPath); ctx.setFillColor(mkColor([6, 6, 7], 1)); ctx.fillPath()

        // bloom (under pixels; only visible during a confident release)
        let ringRect = R(0.95, 0.95, 22.1, 22.1)
        let ringPath = CGPath(roundedRect: ringRect, cornerWidth: 4.65*S, cornerHeight: 4.65*S, transform: nil)
        if inRel {
            var bloomAmt = cl((lockStr - 0.5)/0.5, 0, 1); if recBonus > 0 { bloomAmt = cl(bloomAmt + 0.25, 0, 1) }
            let b2 = cl((reP - 0.16)/0.18, 0, 1)
            let bloomOp = bloomAmt * sin(b2 * .pi) * 0.32
            if bloomOp > 0.001 {
                ctx.addPath(ringPath); ctx.setStrokeColor(mkColor(WHITE, bloomOp)); ctx.setLineWidth(0.75*S); ctx.strokePath()
            }
        }

        // pixels
        ctx.saveGState()
        ctx.addPath(bgPath); ctx.clip()
        let cw = WD/Double(cols), ch = HT/Double(rows), sz = min(cw, ch) * 0.84
        for col in 0..<cols {
            let lit = Int((hgt[col] * Double(rows)).rounded())
            if lit <= 0 || pwr <= 0.001 { continue }
            for b in 0..<rows {
                if b >= lit { break }
                let row = rows - 1 - b
                let cx = X0 + Double(col)*cw + (cw - sz)/2
                let cy = Y0 + Double(row)*ch + (ch - sz)/2
                let rect = R(cx, cy, sz, sz)
                if missCh > 0 && rm[col][b] < missCh && (0.5 + 0.5*sin(t*0.9 + gp[col][b])) < 0.55 {
                    ctx.setFillColor(mkColor(WHITE, 0.04*pwr)); ctx.fill(rect); continue
                }
                let base = (b == lit-1) ? PUR : spectrum(rows > 1 ? Double(b)/Double(rows-1) : 0)
                var color = Lc(base, GRAY, dsat); if whiteMix > 0 { color = Lc(color, WHITE, whiteMix) }
                let bfl = 0.5 + 0.5*sin(t*fr[col][b] + ph[col][b])
                let op = cl((1 - burn + burn*bfl) * flick(t, gp[col][b]*3.1, inRel ? 0 : fdepth), 0.14, 1) * pwr
                ctx.setFillColor(mkColor(color, op)); ctx.fill(rect)
            }
        }
        ctx.restoreGState()

        // mic glyph (over pixels), with confidence color + breathe/wobble
        let micSat = (1 - c) * 0.55 * (1 - rec)
        let stroke = Lc(WHITE, Lc(REC, GRAY, micSat), pwr)
        let activeOp = cl(0.58 + 0.42*c + rec*0.4, 0, 1)
        let micOp = 0.12 + (activeOp - 0.12)*pwr
        let breathe = cl(0.78 - c, 0, 0.5) * cl((c - 0.28)/0.22, 0, 1) * 0.05 * sin(t * 2 * .pi * 0.55) * pwr
        let wobA = cl((0.42 - c)/0.42, 0, 1) * (1 - rec) * pwr
        let wx = wobA * 0.32 * sin(t*5.3) * sin(t*2.1 + 1)
        let wy = wobA * 0.30 * sin(t*4.1 + 2) * sin(t*1.7)
        var sc = 1 + breathe + rec*0.08*pwr
        if inSnap { sc = 1 - 0.05*sin(snP * .pi) }
        if inRel && reP < 0.4 { sc = 1 + lockStr*0.05*sin(cl(reP/0.2, 0, 1) * .pi) }

        ctx.saveGState()
        let centerV = P(12, 12)
        ctx.translateBy(x: centerV.x + CGFloat(wx)*S, y: centerV.y - CGFloat(wy)*S)
        ctx.scaleBy(x: CGFloat(sc), y: CGFloat(sc))
        ctx.translateBy(x: -centerV.x, y: -centerV.y)
        let mic = CGMutablePath()
        mic.addRoundedRect(in: R(9, 2, 6, 12), cornerWidth: 3*S, cornerHeight: 3*S)   // capsule body
        mic.move(to: P(6, 12))                                                          // U cradle
        mic.addArc(center: P(12, 12), radius: 6*S, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        mic.move(to: P(12, 18)); mic.addLine(to: P(12, 20.6))                           // stem
        mic.move(to: P(8.6, 20.7)); mic.addLine(to: P(15.4, 20.7))                       // base
        ctx.addPath(mic)
        ctx.setStrokeColor(mkColor(stroke, micOp)); ctx.setLineWidth(1.5*S)
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
        ctx.restoreGState()

        // release lock ring (white when confident, muted/partial/stuttering when not)
        if inRel {
            let C = lockStr
            let whiteAmt = cl((C - 0.32)/0.5, 0, 1)
            let lockColor = Lc(MUTE, WHITE, whiteAmt)
            let maxFill = 0.42 + C*0.58
            let fp = cl(reP/0.24, 0, 1); let ez2 = 1 - pow(1-fp, 2)
            let filled = (reP < 0.24 ? maxFill*ez2 : maxFill)
            let fade = reP < 0.55 ? 1.0 : cl(1 - (reP-0.55)/0.45, 0, 1)
            let stutter = 1 - (1-C)*(0.32*(0.5 + 0.5*sin(t*26)) + ((sin(t*47 + reP*9) > 0.5) ? 0.4 : 0))
            let op = (0.42 + 0.5*C) * 0.9 * fade * max(0.22, stutter)

            // total perimeter of the rounded-rect ring, in view units, for the partial sweep
            let w = 22.1*S, r = 4.65*S
            let perim = 2*(w + w - 4*r) + 2 * .pi * r
            let dashLen = CGFloat(filled) * perim
            if whiteAmt > 0 {
                ctx.addPath(ringPath); ctx.setStrokeColor(mkColor(lockColor, op*0.45*whiteAmt))
                ctx.setLineWidth(0.5*S); ctx.setLineCap(.round)
                ctx.setLineDash(phase: 0, lengths: [dashLen, perim]); ctx.strokePath()
            }
            ctx.addPath(ringPath); ctx.setStrokeColor(mkColor(lockColor, op))
            ctx.setLineWidth(0.33*S); ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [dashLen, perim]); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }
}
