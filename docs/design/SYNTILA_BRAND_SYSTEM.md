> Current palette (October 29, 2026): Precision Indigo. See
> [Branding](../BRANDING.md#precision-indigo-ui-palette) for the current tokens
> and asset generation process. This palette supersedes earlier blue accents below.

# Syntila Brand & Design System Specification

**Status:** Canonical  
**Version:** 1.0.0  
**Last Updated:** 2026-10-07  

---

## 1. Executive Summary & Design Principles

This specification establishes the source of truth for the Syntila brand and visual language. It represents a **controlled brand-system consolidation**, unifying all Syntila client applications (`apps/app`, `apps/connect`, `apps/profile_lab`), web surfaces, and collateral without altering the essential character of Syntila.

### Core Principles
1. **Intentionality over Novelty:** Every color, radius, and font size corresponds to a documented semantic token.
2. **Atmospheric Contrast:** Light mode leverages a warm editorial canvas (`#F8F7F3`) with crisp surfaces; dark mode employs a deep obsidian/slate canvas (`#121217`) with elevated surface layering.
3. **Monospace Precision:** Engineering artifacts, model identifiers, CLI arguments, digests, and session identifiers use dedicated monospace styling.
4. **Restraint & Governance:** Brand accents must remain focused and distinctive.

---

## 2. Governance Rules

> [!IMPORTANT]
> **Core Palette Rule:**  
> **New arbitrary purple shades are not allowed unless they represent a documented semantic purpose.**  
> Ad-hoc hex values (`#7C3AED`, `#8B5CF6`, `#2D234A`, etc.) must not be introduced in component code. All UI surfaces must strictly resolve to the approved tokens defined in this document.

- **Token-First Implementation:** UI components must consume tokens via `SyntilaBrand`, `Theme.of(context).colorScheme`, or equivalent CSS variables.
- **Cross-Platform Parity:** Flutter clients, CSS styles, and marketing surfaces share identical token definitions and semantic roles.
- **Audit Requirement:** PRs introducing new visual styles must update this document if token mappings or semantic roles evolve.

---

## 3. Approved Color Palette (Source of Truth)

### 3.1 Brand Tokens
| Token | Hex | Light Usage | Dark Usage | Semantic Intent |
|---|---|---|---|---|
| `primary` | `#5E4BD8` | Primary button fill, focus rings, brand badges | Primary button fill, focus rings, brand badges | Core brand action and active indicator |
| `primaryPressed` | `#4937BD` | Active/pressed state on primary buttons | Active/pressed state on primary buttons | Interaction feedback for primary controls |
| `primaryForeground` | `#5E4BD8` (L) / `#B8A9FE` (D) | Brand text on canvas/surface | Brand text on dark canvas/surface | High-contrast brand typography & icons |
| `primarySoft` | `#DEDCF4` | Selected chip background, soft alert backdrops | N/A | Low-contrast brand wash in light mode |
| `primarySoftDark` | `#231D47` | N/A | Selected chip background, soft alert backdrops | Low-contrast brand wash in dark mode |
| `navigationSelected`| `#302D4B` | N/A | Active rail/sidebar item background | High-contrast selected navigation item |

---

### 3.2 Light Theme Surface & Ink Tokens
| Token | Hex | Role | Example Usage |
|---|---|---|---|
| `canvas` | `#F8F7F3` | Root page background | Scaffold background, content backdrop |
| `surface` | `#FFFFFF` | Elevated container | Cards, bottom sheets, dropdown menus, modals |
| `surfaceHover` | `#F1EFE8` | Interactive hover state | Hovered list items, hovered buttons, input chips |
| `border` | `#DFDED8` | Structural boundary | Card borders, dividers, unselected input borders |
| `textPrimary` | `#20202A` | Primary typography | Headings, user prompts, assistant text, labels |
| `textSecondary` | `#6E6E7C` | Muted typography | Subtitles, timestamps, metadata, captions |
| `codeBackground` | `#F0EEE8` | Code & terminal surface | Inline code spans, snippet blocks, diff gutters |

---

### 3.3 Dark Theme Surface & Ink Tokens
| Token | Hex | Role | Example Usage |
|---|---|---|---|
| `canvas` | `#121217` | Root page background | Scaffold background, content backdrop |
| `surface` | `#1A1A22` | Elevated container | Cards, bottom sheets, dropdown menus, modals |
| `surfaceHover` | `#24242F` | Interactive hover state | Hovered list items, hovered buttons, input chips |
| `border` | `#2E2E3A` | Structural boundary | Card borders, dividers, unselected input borders |
| `textPrimary` | `#F4F4F6` | Primary typography | Headings, user prompts, assistant text, labels |
| `textSecondary` | `#9E9EAF` | Muted typography | Subtitles, timestamps, metadata, captions |
| `codeBackground` | `#15151D` | Code & terminal surface | Inline code spans, snippet blocks, terminal views |

---

### 3.4 Semantic Status Tokens
| State | Core Accent | Light Wash (`*Wash`) | Dark Wash (`*WashDark`) | Semantic Intent |
|---|---|---|---|---|
| `success` | `#22C55E` | `#DCFCE7` | `#14532D` | Completed steps, healthy worker connections, verified evidence |
| `warning` | `#F59E0B` | `#FEF3C7` | `#78350F` | Pending approvals, fallback executions, degraded readiness |
| `error` | `#EF4444` | `#FEE2E2` | `#7F1D1D` | Step failures, execution timeouts, connection errors |
| `info` | `#3B82F6` | `#DBEAFE` | `#1E3A8A` | Documentation links, technical details, general notices |

---

## 4. Typography System

### 4.1 Typeface Families
- **UI & Editorial Text:** `Inter`, fallback `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif`.
- **Code, Hashes & Technical Identifiers:** `JetBrains Mono`, fallback `Fira Code, SFMono-Regular, Menlo, Monaco, Consolas, monospace`.

### 4.2 Type Hierarchy
| Style | Size | Line Height | Weight | Letter Spacing | Target Use Cases |
|---|---|---|---|---|---|
| `displayLarge` | 24px | 30px | 700 | -0.02em | Main space hero titles |
| `titleLarge` | 20px | 26px | 700 | -0.015em | Page headers, modal sheet headers |
| `titleMedium` | 16px | 22px | 600 | -0.01em | Card headers, section headings |
| `titleSmall` | 14px | 20px | 600 | 0.0em | Group labels, form section titles |
| `bodyLarge` | 14px | 20px | 400 | 0.0em | Primary markdown body, long-form discussion |
| `bodyMedium` | 13px | 18px | 400 / 500 | 0.0em | Default message text, list tile content |
| `bodySmall` | 12px | 16px | 400 / 500 | 0.01em | Metadata, captions, secondary badges, hints |
| `codeSmall` | 12px | 16px | 500 (Mono) | 0.0em | Inline code chips, tokens, digests, arguments |
| `codeBlock` | 13px | 20px | 400 (Mono) | 0.0em | Code review blocks, execution logs, terminals |

---

## 5. Spacing Scale

Syntila follows a strict **4px / 8px modular spacing grid**:

| Token | Size | Common Use Cases |
|---|---|---|
| `xxs` | 2px | Micro gaps, border offsets, badge inner padding |
| `xs` | 4px | Tight element spacing, icon-to-label gaps, tag margins |
| `sm` | 8px | Button internal padding, chip spacing, compact card margins |
| `md` | 12px | List item vertical spacing, control group gaps |
| `lg` | 16px | Card internal padding, form row gutters, standard container margins |
| `xl` | 20px | Modal padding, pane internal margins |
| `xxl` | 24px | Major section breaks, card stack spacing |
| `xxxl` | 32px | Empty-state vertical padding, hero section gaps |
| `huge` | 48px | Page-level top/bottom layout boundaries |

---

## 6. Border Radii Scale

| Token | Radius | Target Components |
|---|---|---|
| `xs` | 4px | Small status badges, model tags, code chip containers |
| `sm` | 6px | Compact buttons, tooltip wrappers, sub-menus |
| `md` | 8px–10px | Text inputs, dropdown menus, action sheets, standard buttons |
| `lg` | 12px–14px | Cards, thread panels, content viewport splitters |
| `xl` | 16px–20px | Modal dialogs, bottom sheets, onboarding hero containers |
| `pill` | 9999px | Filter chips, avatar badge rings, rounded pill buttons |

---

## 7. Icon Sizing Matrix

Icons must strictly align with the typographic scale and optical sizing:

| Size | Intent & Components |
|---|---|
| **14px** | Inline metadata icons (elapsed time, calendar timestamp, dropdown carets) |
| **16px** | Compact toolbar buttons, input field clear/copy actions, badge icons |
| **18px** | Standard action buttons, bottom composer toolbar icons, tab icons |
| **20px** | Primary navigation icons, pane header controls |
| **24px** | Dialog icons, empty-state headers, full-screen indicators |
| **32px+** | Brand hero graphics and illustration marks |

---

## 8. Brand Mark & Logo Rules

The approved transparent artwork supplied on October 7, 2026 is the official
identity across all product surfaces. `assets/branding/syntila_source.png` is
preserved at its original resolution. All logo sizes, SVG wrappers, wordmarks,
favicons, macOS icons, PWA icons and social previews derive from that source.
SVGs embed the approved raster rather than claiming vector geometry. Existing
variant filenames preserve the same full-color artwork in both themes.

Preserve the central negative space and colors. Do not add glows, letter overlays
or distort the aspect ratio. Keep clear space around the mark. Maskable icons
use dedicated padded opaque derivatives. Generate and verify using
`scripts/branding/build-brand-assets.sh` and its `--check` mode; never hand-edit
app copies. See [Branding](../BRANDING.md) for prerequisites and output details.

---

## 9. Surface Elevation & Layering Model

### Light Mode Hierarchy
```
Level 0: Canvas (#F8F7F3)
  └── Level 1: Surface Container (#FFFFFF, Border #DFDED8)
        └── Level 2: Surface Hover / Chip (#F1EFE8)
              └── Level 3: Code / Pre (#F0EEE8)
```

### Dark Mode Hierarchy
```
Level 0: Canvas (#121217)
  └── Level 1: Surface Container (#1A1A22, Border #2E2E3A)
        └── Level 2: Surface Hover / Chip (#24242F)
              └── Level 3: Code / Terminal (#15151D)
```

---

## 10. Summary Matrix for Developers

When implementing UI components across Syntila:
- **Buttons / Actions:** Primary `#5E4BD8`, Pressed `#4937BD`, Text `#FFFFFF`, Radius `md` (10px).
- **Cards / Containers:** Light `#FFFFFF` on `#F8F7F3` with border `#DFDED8`; Dark `#1A1A22` on `#121217` with border `#2E2E3A`, Radius `lg` (12px).
- **Inputs:** Fill matches Surface, Border matches Border token, Focused Border `#5E4BD8` (1.5px), Radius `md` (10px).
- **Text:** Primary Light `#20202A` / Dark `#F4F4F6`; Secondary Light `#6E6E7C` / Dark `#9E9EAF`.
- **Code:** Background Light `#F0EEE8` / Dark `#15151D`, Font `JetBrains Mono` / Monospace.
- **Brand Purple Usage:** Strictly `#5E4BD8` / `#4937BD` / `#DEDCF4` / `#231D47` / `#B8A9FE`. No ad-hoc variations.
