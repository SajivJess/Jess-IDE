---
name: Jess Ide Dev
colors:
  surface: '#131319'
  surface-dim: '#131319'
  surface-bright: '#3a3840'
  surface-container-lowest: '#0e0d14'
  surface-container-low: '#1c1b22'
  surface-container: '#201f26'
  surface-container-high: '#2a2931'
  surface-container-highest: '#35343c'
  on-surface: '#e5e1eb'
  on-surface-variant: '#cbc3d7'
  inverse-surface: '#e5e1eb'
  inverse-on-surface: '#312f37'
  outline: '#958ea0'
  outline-variant: '#494454'
  surface-tint: '#d0bcff'
  primary: '#d0bcff'
  on-primary: '#3c0091'
  primary-container: '#a078ff'
  on-primary-container: '#340080'
  inverse-primary: '#6d3bd7'
  secondary: '#ccbeff'
  on-secondary: '#332664'
  secondary-container: '#4a3d7c'
  on-secondary-container: '#baabf3'
  tertiary: '#ffb869'
  on-tertiary: '#482900'
  tertiary-container: '#ca801e'
  on-tertiary-container: '#3f2300'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#e9ddff'
  primary-fixed-dim: '#d0bcff'
  on-primary-fixed: '#23005c'
  on-primary-fixed-variant: '#5516be'
  secondary-fixed: '#e7deff'
  secondary-fixed-dim: '#ccbeff'
  on-secondary-fixed: '#1e0e4e'
  on-secondary-fixed-variant: '#4a3d7c'
  tertiary-fixed: '#ffdcbb'
  tertiary-fixed-dim: '#ffb869'
  on-tertiary-fixed: '#2c1700'
  on-tertiary-fixed-variant: '#673d00'
  background: '#131319'
  on-background: '#e5e1eb'
  surface-variant: '#35343c'
  surface-main: '#1C1A24'
  surface-elevated: '#24222D'
  text-primary: '#F5F3FA'
  text-secondary: '#A6A1B3'
  border-subtle: '#353140'
  status-success: '#34D399'
  status-warning: '#FBBF24'
  status-error: '#F87171'
  status-info: '#60A5FA'
typography:
  headline-xl:
    fontFamily: Inter
    fontSize: 2rem
    fontWeight: '600'
    lineHeight: 2.5rem
    letterSpacing: -0.02em
  headline-xl-mobile:
    fontFamily: Inter
    fontSize: 1.5rem
    fontWeight: '600'
    lineHeight: 2rem
    letterSpacing: -0.01em
  headline-lg:
    fontFamily: Inter
    fontSize: 1.5rem
    fontWeight: '600'
    lineHeight: 2rem
    letterSpacing: -0.01em
  headline-md:
    fontFamily: Inter
    fontSize: 1.25rem
    fontWeight: '600'
    lineHeight: 1.75rem
    letterSpacing: -0.01em
  headline-sm:
    fontFamily: Inter
    fontSize: 1rem
    fontWeight: '600'
    lineHeight: 1.5rem
  body-lg:
    fontFamily: Inter
    fontSize: 1rem
    fontWeight: '400'
    lineHeight: 1.5rem
  body-md:
    fontFamily: Inter
    fontSize: 0.875rem
    fontWeight: '400'
    lineHeight: 1.25rem
  body-sm:
    fontFamily: Inter
    fontSize: 0.75rem
    fontWeight: '400'
    lineHeight: 1rem
  code-md:
    fontFamily: JetBrains Mono
    fontSize: 0.875rem
    fontWeight: '400'
    lineHeight: 1.375rem
  code-sm:
    fontFamily: JetBrains Mono
    fontSize: 0.75rem
    fontWeight: '400'
    lineHeight: 1.125rem
  label-md:
    fontFamily: Inter
    fontSize: 0.875rem
    fontWeight: '500'
    lineHeight: 1.25rem
  label-sm:
    fontFamily: JetBrains Mono
    fontSize: 0.6875rem
    fontWeight: '500'
    lineHeight: 0.875rem
    letterSpacing: 0.04em
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  gutter: 1rem
  gutter-desktop: 1.5rem
  margin: 1rem
  margin-desktop: 1.5rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 0.75rem
  space-lg: 1rem
  space-xl: 1.5rem
  space-2xl: 2rem
---

## Brand & Style

The design system establishes a focused, calm, and utilitarian workspace crafted specifically for developers, systems engineers, and technical builders. The design personality centers on clarity, sober restraint, and technical credibility, stripping away unnecessary embellishments in favor of immediate situational awareness and code density. The interface avoids speculative consumer trends—prohibiting neon glows, ambient AI graphics, glossy gradients, and novelty micro-interactions.

Rooted in a Modern Developer-Tool aesthetic, the system balances high information density with deliberate visual quietude. Structural discipline is achieved through hairline borders, precise typographic alignment, monospaced metadata streams, and honest system status indicators. Surfaces feel grounded and matte, letting code, structural diffs, and live telemetry take primary focus.

## Colors

The system uses a dark charcoal palette engineered for low eye fatigue during extended development sessions. Rather than pure black or neutral gray, canvas tones are infused with faint violet-black undertones (`#15141B`, `#1C1A24`, `#24222D`), producing subtle thermal depth without distracting tint.

Primary purple (`#8B5CF6`) is reserved strictly for affirmative actions, primary focus states, and explicit navigation selections. Light lavender (`#C4B5FD`) acts as a secondary accent for inline highlights and active badges. Structural boundaries rely entirely on the hairline rule color (`#353140`).

Functional status colors communicate accurate system diagnostics:
- `status-success` (`#34D399`): Successful task completion, passing builds, and healthy workspace states.
- `status-warning` (`#FBBF24`): Unsaved changes, degraded latency, dependency warnings, or required reviews.
- `status-error` (`#F87171`): Runtime failures, broken diffs, destructive action buttons, and disconnects.
- `status-info` (`#60A5FA`): Active indexing, metadata syncs, and telemetry notes.

## Typography

Typography establishes an unambiguous visual hierarchy between administrative controls, interface copy, and computational outputs. The dual-family pairing consists of `Inter` for interface structure, prose, form controls, and titles, paired with `JetBrains Mono` for terminal sessions, code snippets, git hashes, file paths, diff views, and technical telemetry labels.

`Inter` uses neutral tabular numbers (`tnum`) for data grids, performance metrics, and counter badges. `JetBrains Mono` is enforced with strict vertical alignment for syntax tokens, ensuring uniform character width across multi-line code diffs and diagnostic outputs.

## Layout & Spacing

The system runs on a strict 4px base spatial unit, ensuring geometric rhythm across panel splits, component padding, and alignment grids.

### Form Factors & Breakpoints

- **Desktop (≥ 1024px)**: Uses a 3-column layout model:
  - Collapsible left rail/sidebar (240px–280px) for file trees and module navigation.
  - Central primary work area for execution flows, code editors, and terminals.
  - Contextual right inspector (300px–360px) for metadata, live diagnostics, and history.
  - Forms, settings panels, and documentation blocks enforce a maximum reading width of 720px to prevent excessive line lengths. Code editors, log streamers, and diff views are exempt and expand fluidly to fill 100% of the active container.
- **Tablet (768px – 1023px)**: The right inspector collapses into an off-canvas drawer. The left navigation collapses into an icon-only strip.
- **Mobile (360px – 430px)**: Reflows to a single-column layout. The left navigation collapses into a slide-over panel. Sticky contextual action sheets replace full desktop modal dialogues. Permanent bottom app navigation bars are intentionally prohibited to maximize available vertical height for code and terminal streams.

## Elevation & Depth

Visual hierarchy uses flat tonal layering and precise surface stacking rather than drop shadows or heavy blur effects:

1. **Base Layer (`#15141B`)**: Root canvas, background behind split panes, and application outer frame.
2. **Surface Layer 1 (`#1C1A24`)**: Primary UI surfaces, editor panes, main terminal canvases, and settings panels.
3. **Surface Layer 2 (`#24222D`)**: Elevated surfaces such as popovers, command palettes, dropdown selectors, modal sheets, and floating toolbars.

Separation between these tiers is achieved through solid 1px hairline borders (`#353140`) on the edges of all panels. Heavy cast shadows and colorful ambient blurs are excluded. On top-level elevated containers (e.g., command palettes), a subtle, restrained shadow (`0 8px 24px rgba(0, 0, 0, 0.45)`) may be applied strictly to visually detach the elevated element from the active canvas behind it.

## Shapes

The design system enforces a compact shape language with subtle, restrained corners (scale `1`). Standard interactive components—such as inputs, action buttons, table cell wrappers, and chips—use a default `0.25rem` (4px) corner radius. Panels, modular cards, and modal containers use `0.5rem` (8px). 

Pill-shaped radii and oversized circular wrappers are prohibited for functional controls, reserving rounded-full geometry exclusively for circular avatar containers and status indicator dots. This keeps UI edges crisp, clean, and aligned with monospaced code blocks and tabular data layouts.

## Components

### Buttons
- **Touch Target**: Standard height of 44px to 48px on mobile and primary workflows; 36px permitted exclusively in high-density desktop toolbars.
- **Primary**: Background `#8B5CF6`, text `#F5F3FA`, font-weight 500, radius `0.25rem`. Hover shifts to `#7C3AED`; active state shifts to `#6D28D9`. Focus outline displays a 2px solid `#8B5CF6` ring offset by 2px with `#15141B`.
- **Secondary / Ghost**: Background transparent, border 1px solid `#353140`, text `#F5F3FA`. Hover transitions background to `#24222D`.
- **Destructive**: Background transparent, border 1px solid `#F87171`, text `#F87171`. Hover transitions background to `rgba(248, 113, 113, 0.1)`.

### Form Inputs & Textareas
- **Container**: Background `#1C1A24`, border 1px solid `#353140`, radius `0.25rem`, height 44px (multi-line textarea has min-height 96px).
- **Text & Placeholder**: Value text `#F5F3FA`, placeholder text `#A6A1B3`.
- **States**: Focused inputs highlight border to `#8B5CF6` with a crisp outer glow ring (`0 0 0 1px #8B5CF6`). Invalid inputs swap border and helper text to `#F87171`.

### Checkboxes & Radios
- **Size**: 18px × 18px box with 44px transparent tap target padding.
- **Unchecked**: Background `#1C1A24`, border 1px solid `#353140`.
- **Checked**: Background `#8B5CF6`, border 1px solid `#8B5CF6`, white interior checkmark or center pip.

### Chips & Status Badges
- **Structure**: Inline-flex, radius `0.25rem`, padding 2px 8px, font-family `JetBrains Mono`, text `label-sm`.
- **Variants**:
  - Success: Text `#34D399`, background `rgba(52, 211, 153, 0.1)`, border 1px solid `rgba(52, 211, 153, 0.2)`.
  - Warning: Text `#FBBF24`, background `rgba(251, 191, 36, 0.1)`, border 1px solid `rgba(251, 191, 36, 0.2)`.
  - Error: Text `#F87171`, background `rgba(248, 113, 113, 0.1)`, border 1px solid `rgba(248, 113, 113, 0.2)`.
  - Neutral / Info: Text `#60A5FA`, background `rgba(96, 165, 250, 0.1)`, border 1px solid `rgba(96, 165, 250, 0.2)`.

### Cards & Panels
- **Structure**: Background `#1C1A24`, border 1px solid `#353140`, border-radius `0.5rem`, padding `1rem` to `1.5rem`.
- **Header**: Separated by an internal 1px border `#353140`, containing uppercase or medium title copy paired with action slots.

### Code Viewer & Diff Blocks
- **Canvas**: Background `#15141B`, text `#F5F3FA`, border 1px solid `#353140`, typography `code-md`.
- **Line Highlighting**:
  - Inserted lines: Background `rgba(52, 211, 153, 0.08)`, border-left 3px solid `#34D399`.
  - Deleted lines: Background `rgba(248, 113, 113, 0.08)`, border-left 3px solid `#F87171`.

### File Uploader
- **Desktop**: Drop zone bordered with a dashed 1px stroke `#353140`, surface `#1C1A24`, containing an upload icon, label, format constraints, and counter badge (`0/10`). Drag-over state transitions border to `#8B5CF6` and background to `#24222D`.
- **Mobile**: Compact file selector button with file list summary items stacked below.