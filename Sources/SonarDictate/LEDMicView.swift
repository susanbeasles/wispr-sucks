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
    private var wasLow = false   // confidence dipped low; arms the recovery bloom on the way back up
    private var wasSilent = false   // a real pause happened; arms a bloom when speech resumes
    private var silentSince = 0.0   // last time energy was clearly present

    // event clocks (seconds, CACurrentMediaTime)
    private var tNow = 0.0
    private var snapStart = -9.0, recStart = -9.0, relStart = -9.0
    private var lockStr = 0.0, recBonus = 0.0
    private let relDur = 0.85   // release/lock arc seconds (key-up -> powered down). Longer so the lock sweep is actually seen travel around.
    private var releasing = false, idle = true
    private var lastSnapSeen = 0.0

    private var timer: Timer?

    // Precomputed per-row base spectrum color (static; depends only on the row).
    // Flat scalar arrays so the per-cell hot path never allocates a [Double].
    private var rowR = [Double](), rowG = [Double](), rowB = [Double]()
    private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

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
        rowR = []; rowG = []; rowB = []
        for b in 0..<rows {
            let s = spectrum(rows > 1 ? Double(b)/Double(rows-1) : 0)
            rowR.append(s[0]); rowG.append(s[1]); rowB.append(s[2])
        }
    }

    // Map raw RMS to the 0..1 energy that drives bar height. Boosted gain +
    // lower noise floor so normal speech climbs the bars instead of barely
    // creeping off the bottom. (Tune `gain` up/down for more/less sensitivity.)
    private func energyCurve(_ rms: Float) -> Double {
        let r = Double(rms)
        if r < 0.0015 { return 0 }
        // Soft compression instead of a hard cap. Gain set HIGH because the mic
        // signal here is quiet (normal speech was only filling ~25%). Now normal
        // speech fills most of the bars; loud peaks ride the top still wiggling
        // (the compression asymptote) rather than slamming a dead-flat slab.
        // (Raise `gain` for more sensitivity; raise the 0.5 for more headroom.)
        let g = sqrt(r) * 14.0
        return min(1, g / (1 + g * 0.5))
    }

    // MARK: - Lifecycle (RecordingOverlay show/hide)

    func beginListening() {
        idle = false; releasing = false
        prevCtar = 1; wasLow = false; wasSilent = false; for i in 0..<hgt.count { hgt[i] = 0 }
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
        // 60fps for the smooth EQ. The per-frame cost is now allocation-free (see
        // draw): scalar color math + raw component fills, no CGColor/array churn.
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
            let realE = energyCurve(s.energy)
            // Confidence = the recognizer's REAL transcriptionConfidence, OVERRIDDEN
            // by a starvation check (uses REAL energy, not the display baseline below,
            // so a quiet pause doesn't falsely read as failure). If you're clearly
            // talking but the recognizer hasn't produced a result for a while, drive
            // confidence down - that's the "loud but nothing transcribes" case.
            let realConf = Double(s.confidence)
            let sinceResult = t - s.lastResultAt
            var keepingUp = 1.0
            if realE > 0.2 && s.lastResultAt > 0 {
                keepingUp = cl(1 - (sinceResult - 1.0) / 1.5, 0, 1)   // 1s grace, fully starved by 2.5s
            }
            Ctar = min(realConf, keepingUp)
            // Bars get a baseline floor while recording so the colors are MOVING the
            // instant the widget grows - not dead for a second while audio warms up.
            E = max(realE, 0.3)
        }
        // noise estimate from energy jitter (no acoustic-noise signal yet)
        let jitter = abs(E - ePrev); ePrev = E
        Ntar += (cl(jitter * 7, 0.05, 0.9) - Ntar) * 0.15

        // finalize snap (real event from the recognizer)
        if s.lastSnapAt != lastSnapSeen && s.lastSnapAt > 0 && !idle && !releasing {
            snapStart = t; lastSnapSeen = s.lastSnapAt
        }
        // confidence climbing sharply -> heel bloom (recovery)
        // Recovery bloom on a real low->high climb (not a per-frame delta, which
        // the gradual proxy never produced - that's why recovery "wouldn't come
        // back"). Arm when confidence dips low, fire the white heel when it climbs
        // back up.
        if Ctar < 0.4 { wasLow = true }
        if !releasing, wasLow, Ctar > 0.7 { recStart = t; wasLow = false }
        prevCtar = Ctar

        e += (E - e) * 0.18
        c += (Ctar - c) * 0.08
        nz += (Ntar - nz) * 0.1

        let reP = (t - relStart) / relDur
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

        // Only trigger the expensive 324-cell redraw when something is actually
        // visible or animating. Don't burn the draw on silence or a fully-decayed
        // frame. The cheap per-column math above still runs every tick so we catch
        // the instant speech returns (no lag), but the draw is skipped when there
        // is nothing to show.
        if idle {
            needsDisplay = true   // one final frame: the powered-down black tile
            stopTimer()
            return
        }
        let recActive = (t - recStart) < 0.6
        let snapActive = (t - snapStart) < 0.13
        var anyLit = false
        for col in 0..<cols where hgt[col] * Double(rows) >= 0.5 { anyLit = true; break }
        needsDisplay = releasing || recActive || snapActive || anyLit
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
        let reP = (t - relStart) / relDur
        let inRel = releasing && reP >= 0 && reP < 1
        let pwr = releasing ? (reP < 0.4 ? 1.0 : cl(1 - (reP-0.4)/0.5, 0, 1)) : (idle ? 0.0 : 1.0)
        let snP = (t - snapStart) / 0.13
        let inSnap = snP >= 0 && snP < 1 && !idle && !releasing
        var gap = cl(1 - c, 0, 1); if inSnap { gap *= (1 - snP) }; gap *= (1 - rec)
        // Stronger degradation: more desaturation, flicker kicks in earlier, and
        // missing black squares start sooner and appear more often when unsure.
        let dsat = gap * 0.78, whiteMix = rec * 0.42
        let fdepth = cl((gap - 0.08)/0.6, 0, 1)
        let missCh = gap > 0.35 ? (gap - 0.35)*0.7 : 0

        // tile background #060607, clip pixels to it
        let bg = R(0.6, 0.6, 22.8, 22.8)
        let bgPath = CGPath(roundedRect: bg, cornerWidth: 5*S, cornerHeight: 5*S, transform: nil)
        ctx.addPath(bgPath); ctx.setFillColor(mkColor([6, 6, 7], 1)); ctx.fillPath()

        // bloom (under pixels; only visible during a confident release)
        let ringRect = R(0.95, 0.95, 22.1, 22.1)
        let ringPath = CGPath(roundedRect: ringRect, cornerWidth: 4.65*S, cornerHeight: 4.65*S, transform: nil)
        // Edge ring that hugs the CONTAINER rim (vs the inset ringPath). Used by the
        // recording pulse and the release lock so the EDGE itself lights up with no
        // black gap outside it. Inset ~half the rim stroke so the stroke's outer edge
        // lands on the container edge (masksToBounds clips anything beyond it).
        let edgeRect = R(0.75, 0.75, 22.5, 22.5)
        let edgePath = CGPath(roundedRect: edgeRect, cornerWidth: 5.4*S, cornerHeight: 5.4*S, transform: nil)
        if inRel {
            var bloomAmt = cl((lockStr - 0.5)/0.5, 0, 1); if recBonus > 0 { bloomAmt = cl(bloomAmt + 0.25, 0, 1) }
            let b2 = cl((reP - 0.16)/0.18, 0, 1)
            let bloomOp = bloomAmt * sin(b2 * .pi) * 0.32
            if bloomOp > 0.001 {
                ctx.addPath(ringPath); ctx.setStrokeColor(mkColor(WHITE, bloomOp)); ctx.setLineWidth(0.75*S); ctx.strokePath()
            }
        }

        // pixels - ALLOCATION-FREE hot path. The old code allocated a CGColor plus
        // a couple of [Double] arrays (Lc/spectrum) PER CELL PER FRAME - hundreds of
        // heap allocations every frame, the resource hog. Here the colorspace is set
        // once, the color math is inlined to scalars, and raw components are fed to a
        // single reused buffer. Output is byte-identical to the mockup.
        ctx.saveGState()
        ctx.addPath(bgPath); ctx.clip()
        ctx.setFillColorSpace(srgbSpace)
        var comps: [CGFloat] = [0, 0, 0, 1]
        // 0.95: big squares that nearly fill their slot, only a thin black grid
        // line between them. Fills the tile instead of tiny dots lost in black.
        let cw = WD/Double(cols), ch = HT/Double(rows), sz = min(cw, ch) * 0.95
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
                    comps[0] = 1; comps[1] = 1; comps[2] = 1; comps[3] = CGFloat(0.04*pwr)
                    ctx.setFillColor(comps); ctx.fill(rect); continue
                }
                // base spectrum color (leading lit pixel is always purple = PUR)
                var cr: Double, cg: Double, cb: Double
                if b == lit-1 { cr = 122; cg = 63; cb = 240 } else { cr = rowR[b]; cg = rowG[b]; cb = rowB[b] }
                // desaturate toward GRAY [120,120,130], then recovery white-mix
                cr += (120 - cr)*dsat; cg += (120 - cg)*dsat; cb += (130 - cb)*dsat
                if whiteMix > 0 { cr += (255 - cr)*whiteMix; cg += (255 - cg)*whiteMix; cb += (255 - cb)*whiteMix }
                let bfl = 0.5 + 0.5*sin(t*fr[col][b] + ph[col][b])
                let op = cl((1 - burn + burn*bfl) * flick(t, gp[col][b]*3.1, inRel ? 0 : fdepth), 0.14, 1) * pwr
                comps[0] = CGFloat(cr/255); comps[1] = CGFloat(cg/255); comps[2] = CGFloat(cb/255); comps[3] = CGFloat(op)
                ctx.setFillColor(comps); ctx.fill(rect)
            }
        }
        ctx.restoreGState()

        // mic glyph (over pixels), with confidence color + breathe/wobble.
        // WHITE mic - red is now the recording border's job, so the glyph stays
        // white to pop against it; it only grays out when the recognizer is unsure,
        // and fades with pwr via micOp below.
        let micSat = (1 - c) * 0.55 * (1 - rec)
        let stroke = Lc(WHITE, GRAY, micSat)
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
        ctx.setStrokeColor(mkColor(stroke, micOp)); ctx.setLineWidth(1.05*S)   // thinner glyph
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
        ctx.restoreGState()

        // recording border: a RED rim ON the container edge that pulses while
        // listening, so you can see it's still capturing. Drawn on edgePath (hugs the
        // rim, no inset gap) - the EDGE itself is what pulses - wide, with a soft red
        // glow. Replaced by the white lock ring on release.
        if !releasing && !idle {
            let pulse = 0.5 + 0.4 * (0.5 + 0.5 * sin(t * 3.6))   // ~0.5..0.9
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3.5*S, color: mkColor(REC, pulse))
            ctx.addPath(edgePath)
            ctx.setStrokeColor(mkColor(REC, pulse))
            ctx.setLineWidth(1.6*S); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // release lock ring: sweeps ALL THE WAY around the container edge, then locks
        // and fades. White when confident, muted/partial/stuttering when not. Quick
        // but VISIBLE (the sweep travels over ~half the release arc instead of
        // snapping shut), wide, with a soft glow. Drawn on edgePath so it traces the
        // same rim the red pulse did - the edge locking in, not an inset ring.
        if inRel {
            let C = lockStr
            let whiteAmt = cl((C - 0.32)/0.5, 0, 1)
            let lockColor = Lc(MUTE, WHITE, whiteAmt)
            // Travel (near) the full loop; fully closed when confident.
            let maxFill = cl(0.78 + C*0.30, 0, 1)
            // Fill over the first ~half of the release arc (relDur*sweep ~= 0.43s) so
            // you actually watch it travel around, then it holds, then fades.
            let sweep = 0.5
            let fp = cl(reP/sweep, 0, 1); let ez2 = 1 - pow(1-fp, 2)
            let filled = (reP < sweep ? maxFill*ez2 : maxFill)
            let fade = reP < 0.6 ? 1.0 : cl(1 - (reP-0.6)/0.4, 0, 1)
            let stutter = 1 - (1-C)*(0.32*(0.5 + 0.5*sin(t*26)) + ((sin(t*47 + reP*9) > 0.5) ? 0.4 : 0))
            let op = (0.42 + 0.5*C) * 0.95 * fade * max(0.22, stutter)

            // perimeter of edgePath (rounded square) in view units, for the sweep dash
            let side = 22.5*S, r = 5.4*S
            let perim = 4*side - 8*r + 2 * .pi * r
            let dashLen = CGFloat(filled) * perim
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3.0*S, color: mkColor(lockColor, op*whiteAmt))
            if whiteAmt > 0 {
                ctx.addPath(edgePath); ctx.setStrokeColor(mkColor(lockColor, op*0.45*whiteAmt))
                ctx.setLineWidth(1.4*S); ctx.setLineCap(.round)
                ctx.setLineDash(phase: 0, lengths: [dashLen, perim]); ctx.strokePath()
            }
            ctx.addPath(edgePath); ctx.setStrokeColor(mkColor(lockColor, op))
            ctx.setLineWidth(0.8*S); ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [dashLen, perim]); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.restoreGState()
        }
    }
}
