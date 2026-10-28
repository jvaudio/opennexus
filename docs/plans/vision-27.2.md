# Image import on macOS 27.2

## Problem

On macOS 27.2 (26B123, Xcode 27.1), `ImageRoundTripTests.exportedMapReadsBack` failed in 6
of its 10 layouts. Every export was drawn right; Vision read it differently:

| Layouts | Read back | Cause |
| --- | --- | --- |
| `mindmap.right`, `logic.right` | "Hotel for the team -" | Vision read the connector leaving the topic as a dash |
| `mindmap.balanced` | "Morning <" | Vision read the fork to its children as a chevron |
| `tree.down`, `tree.indented` | Channels, Timeline and Risks under Pricing | "Pricing" boxed 38 px tall against 28–33 for the other main topics: a heading tier in the list |
| `timeline.horizontal` | "Strategy review" as the centre | Subtopics boxed up to 36 px, as tall as the 20 pt root, so the root missed the title threshold (1.15 × median) |

Vision's raw output was checked directly, with the app's own request settings, to rule out
OpenNexus's code: the marks come back from Vision at confidence 1.0, and the same text
in the same export style boxes 24 px tall in one picture and 33 px in another.

## Plan

- **D283 · size from width.** Measure each line's string in the system font (CoreText);
  a line's size is the smaller of its height and its width over its ems. Text widths vary
  far less than Vision's heights.
- **D284 · connector marks.** A lone stroke-like mark at either end of a line, whose ink
  runs out of the line's box, is a connector: drop it, and take Vision's box for the rest.
- **D285 · indents from ink.** Once the size fix let the timeline read as columns, "Trains"
  (box 17 px before its text) still took "Hotel for the team" as its child. The list reads
  indentation from where each line's ink starts; box geometry is otherwise untouched,
  because narrowing whole boxes broke the fishbone sub-cause round trips (D269).

**Accept when:** the round trips pass on macOS 27.2, the full suite and strict lint pass,
and unit tests hold each rule without Vision.

## Results (2026-10-27)

- `ImageRoundTripTests`: all 16 cases pass (10 map layouts, 6 fishbone).
- New, in `ImageOutlineTests`: `sizeIsNeverMoreThanTheWidthImplies`,
  `aBoxTallerThanItsWidthImpliesIsNoHeading` (the 27.2 tree's real boxes; by heights alone
  it nests as before), `indentsStartWhereTheTextsInkDoes` (by box edges it nests as before),
  `connectorMarksRunOutOfTheirLine` (a connector, a fork, and a dash inside the box).
- `swift test`: 637 tests, all passing. `scripts/lint.sh`: clean.

### Known gaps

- Only checked against Vision on macOS 27.2. The rules are meant to hold on earlier
  releases too (they only ever cut a box's size, drop marks whose ink leaves the box, and
  move indents to the text), but CI hasn't run since M13, so no other version has run
  this suite against them.
- A face much narrower than the system font reads a little small. Its lines all shrink by
  the same factor, so comparisons within one picture hold.
