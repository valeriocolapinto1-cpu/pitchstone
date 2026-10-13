import Testing
@testable import PitchstoneNotes

@Suite("Differenze tra versioni")
struct LineDiffTests {
    @Test("modifica in mezzo")
    func middleChange() {
        let diff = LineDiff.diff("a\nb\nc\nd", "a\nB\nc\nd\ne")
        #expect(diff == [.same("a"), .removed("b"), .added("B"), .same("c"), .same("d"), .added("e")])
        #expect(LineDiff.summary(diff) == (added: 2, removed: 1))
    }

    @Test("testi vuoti")
    func empty() {
        #expect(LineDiff.diff("", "").isEmpty)
        #expect(LineDiff.diff("", "x\ny") == [.added("x"), .added("y")])
        #expect(LineDiff.diff("x", "") == [.removed("x")])
    }

    @Test("identici")
    func identical() {
        #expect(LineDiff.diff("a\nb", "a\nb") == [.same("a"), .same("b")])
    }

    @Test("righe spostate")
    func reorder() {
        let diff = LineDiff.diff("a\nb\nc", "c\na\nb")
        #expect(LineDiff.summary(diff) == (added: 1, removed: 1))
        #expect(diff.filter { if case .same = $0 { true } else { false } }.count == 2)
    }

    @Test("note enormi: niente tabella quadratica")
    func huge() {
        let old = (0..<3000).map { "a\($0)" }.joined(separator: "\n")
        let new = (0..<3000).map { "b\($0)" }.joined(separator: "\n")
        #expect(LineDiff.summary(LineDiff.diff(old, new)) == (added: 3000, removed: 3000))
    }
}
