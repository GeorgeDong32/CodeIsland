# Component Guidelines

> How components are built in this project.

---

## Overview

<!--
Document your project's component conventions here.

Questions to answer:
- What component patterns do you use?
- How are props defined?
- How do you handle composition?
- What accessibility standards apply?
-->

(To be filled by the team)

---

## Component Structure

<!-- Standard structure of a component file -->

(To be filled by the team)

---

## Props Conventions

<!-- How props should be defined and typed -->

(To be filled by the team)

---

## Styling Patterns

<!-- How styles are applied (CSS modules, styled-components, Tailwind, etc.) -->

(To be filled by the team)

---

## Accessibility

<!-- A11y requirements and patterns -->

(To be filled by the team)

---

## Common Mistakes

### Recursive Markdown list measurement

`Sources/CodeIsland/MarkdownReplyView.swift` renders list items recursively.
Do not replace `MarkdownListRowLayout` with a generic `HStack` around the marker
and nested blocks. Stack flexibility probes repeatedly measure the child tree;
five levels / 363 items blocked the main thread for 22.429 seconds in the real
completion reply, despite its capped scroll area. Removing text `fixedSize` or
fixing marker width alone did not remove the multiplicative work.

The list-row contract is:

- Exactly two children: the marker, then the item's blocks; preserve that reading
  order, top alignment, and the existing 5-point gap.
- Measure the marker at its ideal size. For a finite offered width, measure the
  body with `max(0, width - markerWidth - 5)` and no height constraint. Nil or
  nonfinite width asks for the body's natural size, without a magic fallback.
- Return the marker plus body width and their maximum height. Place using the
  actual bounds and the same remaining-width calculation. Preserve complete
  text, wrapping, indentation, ordered markers, and checkboxes.
- A height cap is a presentation constraint; it does not bound the cost of
  recursively measuring the scroll view's contents.

```swift
MarkdownListRowLayout {
    MarkdownListMarkerView(marker: marker, fontSize: fontSize)
    MarkdownBlocksView(blocks: item.blocks, fontSize: fontSize, listDepth: depth + 1)
}
```

Validate with `swift test --filter 'Markdown|CompletionCardLayoutTests'`.
`MarkdownListLayoutTests` exercises the production completion reply with a
five-level list, actual panel open/update, minimum/ideal/unbounded proposals,
and rendered marker/wrapping geometry against the former layout at shallow
depth, including short intrinsic-width rows and both layout directions.
The 5-second regression ceiling is deliberately loose for test machines;
it catches the multi-second stall, not ordinary frame-time fluctuations. Keep
test-owned defaults and mascot animation visibility isolated and restore their
prior values afterward. Parsing-only tests or
a simplified replacement view do not protect this rendering path.
