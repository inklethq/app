import AppKit
import IOKit
import Testing
@testable import InkletMac

@Test func optionChordRequiresBothSidesAndRearmsAfterRelease() {
    let left = UInt(NX_DEVICELALTKEYMASK)
    let right = UInt(NX_DEVICERALTKEYMASK)
    var chord = OptionChord()
    let events = [left, left | right, left | right, right, left | right, 0, right, right | left]
    let results = events.map { chord.update(flags: $0) }
    #expect(results == [false, true, false, false, false, false, false, true])
}

@Test func optionChordRejectsOtherModifiersAndOneSidedOption() {
    let both = UInt(NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)
    #expect(!OptionChord.matches(flags: NSEvent.ModifierFlags.option.rawValue))
    for other in [NSEvent.ModifierFlags.command, .shift, .control, .function] {
        #expect(!OptionChord.matches(flags: both | other.rawValue))
    }
    #expect(OptionChord.matches(flags: both | NSEvent.ModifierFlags.option.rawValue))
}
