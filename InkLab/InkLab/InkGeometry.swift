import CoreGraphics
import Foundation

/// Where the student wrote, worked out from the strokes themselves rather than a rectangle drawn round
/// them: which strokes make up one piece of writing, its lines top to bottom, and the words along a line.
/// Pure geometry on stroke bounds (page content coordinates), so it is tested without a canvas.
enum InkGeometry {
    /// About how tall one written letter is here: the median stroke height, ignoring dots and specks. Every
    /// gap below is measured in it, so large and small handwriting behave the same.
    static func letterHeight(_ strokes: [CGRect]) -> CGFloat {
        let heights = strokes.filter { !$0.isNull }.map(\.height).filter { $0 >= 3 }.sorted()
        guard !heights.isEmpty else { return 24 }
        return max(16, heights[heights.count / 2])   // never smaller than small handwriting (a page of dashes)
    }

    /// The strokes grouped into separate pieces of writing (indices into `strokes`, each in writing order).
    /// Words on a line and the lines of one paragraph or one problem's working are one piece, even with a
    /// line left between steps; a clear gap (about three lines or more, or a wide gap across the page)
    /// starts another. It errs toward keeping writing together: cutting a problem's working short is worse
    /// than reading a little extra.
    static func blocks(_ strokes: [CGRect]) -> [[Int]] {
        let valid = strokes.indices.filter { !strokes[$0].isNull }
        guard !valid.isEmpty else { return [] }
        let h = letterHeight(strokes)
        let grown = strokes.map { $0.isNull ? $0 : $0.insetBy(dx: -2 * h, dy: -1.4 * h) }
        var parent = Array(strokes.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        // Sweep top to bottom: once a stroke starts below this one's grown bottom, so do all after it.
        let order = valid.sorted { grown[$0].minY < grown[$1].minY }
        for (k, i) in order.enumerated() {
            for j in order[(k + 1)...] {
                if grown[j].minY > grown[i].maxY { break }
                if grown[i].intersects(grown[j]) {
                    let a = root(i), b = root(j)
                    if a != b { parent[a] = b }
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in valid { groups[root(i), default: []].append(i) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// The piece of writing the student was just working on: of the strokes on screen, the block holding
    /// the one written last. A block that runs past the screen's edge is kept whole.
    static func latestBlock(strokes: [CGRect], visible: CGRect) -> [Int] {
        let near = visible.insetBy(dx: 0, dy: -visible.height)
        let candidates = strokes.indices.filter { !strokes[$0].isNull && strokes[$0].intersects(near) }
        guard let last = candidates.last(where: { strokes[$0].intersects(visible) }) else { return [] }
        let sub = candidates.map { strokes[$0] }
        for block in blocks(sub) {
            let ids = block.map { candidates[$0] }
            if ids.contains(last) { return ids }
        }
        return [last]
    }

    /// `r` sits on the same line of writing as `line`: overlapping its band, and not far off along it.
    static func onSameLine(_ r: CGRect, as line: [CGRect]) -> Bool {
        let line = line.filter { !$0.isNull }
        guard !r.isNull, let first = line.first else { return false }
        let band = line.dropFirst().reduce(first) { $0.union($1) }
        let overlap = min(r.maxY, band.maxY) - max(r.minY, band.minY)
        guard overlap > 0.5 * min(max(r.height, 1), max(band.height, 1)) else { return false }
        let gap = max(band.minX - r.maxX, r.minX - band.maxX, 0)
        return gap <= 4 * letterHeight(line + [r])
    }

    /// Which of `candidates` belong to the same line of writing as `new` (indices into `candidates`), found
    /// word by word along the line, so a long command written in pieces stays one line.
    static func lineMates(_ candidates: [CGRect], of new: [CGRect]) -> [Int] {
        var line = new.filter { !$0.isNull }
        guard !line.isEmpty else { return [] }
        var picked: [Int] = []
        var left = Array(candidates.indices)
        var grew = true
        while grew {
            grew = false
            for i in left where onSameLine(candidates[i], as: line) {
                picked.append(i); line.append(candidates[i]); grew = true
            }
            left.removeAll { picked.contains($0) }
        }
        return picked.sorted()
    }

    /// The lines of writing, top to bottom: strokes that share a line are merged into one band. Dots, commas
    /// and other specks join the line they sit on instead of becoming lines of their own.
    static func rows(_ strokes: [CGRect]) -> [CGRect] {
        let valid = strokes.filter { !$0.isNull }
        let h = letterHeight(valid)
        let isSpeck = { (r: CGRect) in r.height < 0.35 * h && r.width < 0.5 * h }
        var rows: [CGRect] = []
        for r in valid.filter({ !isSpeck($0) }).sorted(by: { $0.midY < $1.midY }) {
            if let last = rows.last {
                let overlap = min(last.maxY, r.maxY) - max(last.minY, r.minY)
                if overlap > 0.3 * min(max(last.height, 1), max(r.height, 1)) { rows[rows.count - 1] = last.union(r); continue }
            }
            rows.append(r)
        }
        guard !rows.isEmpty else { return valid.isEmpty ? [] : [valid.dropFirst().reduce(valid[0]) { $0.union($1) }] }
        for speck in valid.filter(isSpeck) {
            let distance = { (row: CGRect) in max(0, row.minY - speck.midY, speck.midY - row.maxY) }
            if let i = rows.indices.min(by: { distance(rows[$0]) < distance(rows[$1]) }) { rows[i] = rows[i].union(speck) }
        }
        return rows
    }

    /// Exactly `count` lines, top to bottom, for a reading of that many lines. Extra bands (a fraction bar,
    /// an exponent written high) merge into their nearest neighbour; too few (a long line the reading broke
    /// in two, two lines a tall stroke joined) split the band most likely to hold two. nil with no ink.
    static func lines(_ strokes: [CGRect], count: Int) -> [CGRect]? {
        var rows = rows(strokes)
        guard count > 0, !rows.isEmpty else { return nil }
        while rows.count > count {
            let gap = { (i: Int) in rows[i + 1].minY - rows[i].maxY }
            let i = (0..<(rows.count - 1)).min { gap($0) < gap($1) }!
            rows[i] = rows[i].union(rows[i + 1])
            rows.remove(at: i + 1)
        }
        let h = letterHeight(strokes)
        while rows.count < count {
            if let i = rows.indices.max(by: { rows[$0].height < rows[$1].height }), rows[i].height > 1.8 * h {
                let r = rows[i]                       // two lines joined: split top / bottom
                rows.replaceSubrange(i...i, with: [CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2),
                                                   CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)])
            } else {
                let i = rows.indices.max { rows[$0].width < rows[$1].width }!
                let r = rows[i]                       // one long line read as two: split left / right
                rows.replaceSubrange(i...i, with: [CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height),
                                                   CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)])
            }
        }
        return rows
    }

    /// The words along one line of ink, left to right: strokes closer together than a word space are one word.
    static func words(_ strokes: [CGRect]) -> [CGRect] {
        let h = letterHeight(strokes)
        var out: [CGRect] = []
        for r in strokes.filter({ !$0.isNull }).sorted(by: { $0.minX < $1.minX }) {
            if let last = out.last, r.minX - last.maxX < 0.5 * h { out[out.count - 1] = last.union(r) }
            else { out.append(r) }
        }
        return out
    }

    /// The strokes that sit on `line` (their middle inside its band).
    static func strokes(_ strokes: [CGRect], on line: CGRect) -> [CGRect] {
        strokes.filter { !$0.isNull && $0.midY >= line.minY && $0.midY <= line.maxY && $0.maxX >= line.minX && $0.minX <= line.maxX }
    }

    /// One stroke on the page as the eraser left it. The pixel eraser hides the part it rubs out and can cut a
    /// stroke in pieces; the pieces of one stroke share `stroke`.
    struct InkPiece: Equatable {
        /// What still shows.
        var bounds: CGRect
        /// The whole stroke before any erasing (`bounds` when it was never touched).
        var whole: CGRect
        /// How much of the stroke is left, 0...1 over all its pieces (1 when it was never touched).
        var shown: CGFloat
        var stroke: Int
        var written: Date
    }

    /// What's left of writing the student rubbed out, which is never read as writing: a stroke the eraser
    /// took most of, and the rest of a word it took most of, including any strokes it missed altogether
    /// (they were written with that word, within a moment of it). Writing done later on the same spot, a
    /// word that only lost a letter, and a stroke trimmed at its end all still count.
    static func eraseLeftovers(_ pieces: [InkPiece]) -> Set<Int> {
        let rubbed = { (i: Int) in pieces[i].shown < 0.6 }
        var out = Set(pieces.indices.filter { pieces[$0].shown < 0.5 })
        guard pieces.indices.contains(where: rubbed) else { return out }
        for word in wordGroups(pieces.map(\.whole)) where word.contains(where: rubbed) {
            let times = word.filter(rubbed).map { pieces[$0].written }
            let span = times.min()!.addingTimeInterval(-2.5)...times.max()!.addingTimeInterval(2.5)
            let erasedWord = word.filter { rubbed($0) || span.contains(pieces[$0].written) }
            let strokes = Set(erasedWord.map { pieces[$0].stroke })
            let rubbedStrokes = Set(erasedWord.filter(rubbed).map { pieces[$0].stroke })
            if 2 * rubbedStrokes.count > strokes.count { out.formUnion(erasedWord) }
        }
        return out
    }

    /// The strokes grouped into words (indices): on one line, closer together than a letter's height (a word
    /// space, or the gap one letter the eraser took altogether leaves in a word).
    static func wordGroups(_ strokes: [CGRect]) -> [[Int]] {
        let valid = strokes.indices.filter { !strokes[$0].isNull }
        let h = letterHeight(strokes)
        var parent = Array(strokes.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        let order = valid.sorted { strokes[$0].minX < strokes[$1].minX }
        for (k, i) in order.enumerated() {
            for j in order[(k + 1)...] {
                let a = strokes[i], b = strokes[j]
                if b.minX - a.maxX >= h { break }                // sorted by left edge: the rest are further
                let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                guard overlap > 0.3 * min(max(a.height, 1), max(b.height, 1)) else { continue }
                let ra = root(i), rb = root(j)
                if ra != rb { parent[ra] = rb }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in valid { groups[root(i), default: []].append(i) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}

/// What a tutor message is pointing at on the page: the words it quotes from the student's own writing,
/// or the line it names ("line 2"), as rectangles over that ink (one per line it touches). The note lights
/// them up and its connector goes to them, so the student sees exactly what &Co means.
enum TutorFocus {
    /// Spans in double quotes, or in single quotes when they hold two or more words (so an apostrophe is
    /// never mistaken for a quote).
    static func quotes(in text: String) -> [String] {
        var out: [String] = []
        let patterns = [#"["“]([^"”]+)["”]"#, #"(?:^|[\s(])['‘]([^'’]+\s[^'’]+)['’](?=[\s.,;:!?)]|$)"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let q = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty { out.append(q) }
            }
        }
        return out
    }

    /// Page lines named in the message ("line 2", "Line 3").
    static func lineNumbers(in text: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: #"\b[Ll]ine (\d{1,2})\b"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }
    }

    /// A word of a page line: its normalized text and where it sits in the line (character offsets).
    struct Token: Equatable { var line: Int; var word: Int; var start: Int; var end: Int; var text: String }

    static func tokens(_ line: String, index: Int) -> [Token] {
        var out: [Token] = [], offset = 0, current = "", start = 0
        func flush() {
            if !current.isEmpty { out.append(Token(line: index, word: out.count, start: start, end: offset, text: current)) }
            current = ""
        }
        for ch in line {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                if current.isEmpty { start = offset }
                current.append(contentsOf: ch == "’" ? "'" : ch.lowercased())
            } else { flush() }
            offset += 1
        }
        flush()
        return out
    }

    /// Where `quote` is among the page's words: an exact run of its words, else the longest run of at
    /// least two words (and most of the quote). A one-word quote must appear just once to count.
    static func locate(_ quote: String, in pageLines: [String]) -> [Token]? {
        let all = pageLines.enumerated().flatMap { tokens($0.element, index: $0.offset) }
        let q = tokens(quote, index: 0).map(\.text)
        guard !q.isEmpty, !all.isEmpty else { return nil }
        if q.count == 1 {
            let hits = all.filter { $0.text == q[0] }
            return hits.count == 1 ? hits : nil
        }
        var best: (start: Int, length: Int)?
        for i in all.indices {
            for j in q.indices {
                var n = 0
                while i + n < all.count, j + n < q.count, all[i + n].text == q[j + n] { n += 1 }
                if n > (best?.length ?? 0) { best = (i, n) }
            }
        }
        guard let best, best.length == q.count || (best.length >= 2 && Double(best.length) >= 0.6 * Double(q.count)) else { return nil }
        return Array(all[best.start..<(best.start + best.length)])
    }

    /// The page rectangles `reply` points at in `session` (`ink`: the bounds of the page's strokes). Empty
    /// when it quotes nothing from the page and names no line.
    static func rects(for reply: String, session: TutorSession, ink: [CGRect]) -> [CGRect] {
        guard !session.isUnread, !session.lineRects.isEmpty else { return [] }
        let mine = ink.filter { !$0.isNull && $0.intersects(session.problem) }
        var out: [CGRect] = []
        for quote in quotes(in: reply) {
            guard let found = locate(quote, in: session.pageLines) else { continue }
            for line in Set(found.map(\.line)).sorted() where session.lineRects.indices.contains(line) {
                let span = found.filter { $0.line == line }
                out.append(rect(of: span, line: line, session: session, ink: mine))
            }
        }
        if out.isEmpty {
            for n in lineNumbers(in: reply) where session.lineRects.indices.contains(n - 1) {
                // The line's real ink: never stray dots and specks, and never an empty band (better to mark
                // nothing than a box round nothing).
                let onLine = InkGeometry.strokes(mine, on: session.lineRects[n - 1])
                let h = InkGeometry.letterHeight(onLine)
                let marks = onLine.filter { $0.height >= 0.35 * h || $0.width >= 0.5 * h }
                if let first = marks.first { out.append(marks.dropFirst().reduce(first) { $0.union($1) }) }
            }
        }
        var unique: [CGRect] = []
        for r in out where !unique.contains(r) { unique.append(r) }
        return unique
    }

    /// The ink of some words on one line: the matching word of the ink when the line splits into as many
    /// words as were read, else the part of the line where those letters fall, widened to whole words.
    static func rect(of span: [Token], line: Int, session: TutorSession, ink: [CGRect]) -> CGRect {
        let band = session.lineRects[line]
        let onLine = InkGeometry.strokes(ink, on: band)
        let words = InkGeometry.words(onLine)
        let lineTokens = tokens(session.pageLines[line], index: line)
        guard let first = span.first, let last = span.last else { return band }
        if words.count == lineTokens.count, words.indices.contains(last.word) {
            return words[first.word...last.word].dropFirst().reduce(words[first.word]) { $0.union($1) }
        }
        let extent = onLine.isEmpty ? band : onLine.dropFirst().reduce(onLine[0]) { $0.union($1) }
        let length = CGFloat(max(1, session.pageLines[line].count))
        let x0 = extent.minX + extent.width * CGFloat(first.start) / length
        let x1 = extent.minX + extent.width * CGFloat(last.end) / length
        let covered = words.filter { $0.midX >= x0 && $0.midX <= x1 }
        if let w = covered.first { return covered.dropFirst().reduce(w) { $0.union($1) } }
        return CGRect(x: x0, y: extent.minY, width: max(6, x1 - x0), height: extent.height)
    }
}
