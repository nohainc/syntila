# Worker icons

Bundled provider marks identify the worker in the Work response sender row.
Marks belong to their respective owners and do not indicate endorsement.

Sources downloaded October 7, 2026:
- ChatGPT: https://cdn.oaistatic.com/assets/favicon-o20kmmos.svg
  Brand guidance: https://openai.com/brand/
- Claude: https://claude.ai/favicon.ico (largest frame)
- Gemini: https://www.gstatic.com/lamda/images/gemini_sparkle_aurora_33f86dc0c0257da337c63.svg

Source downloaded October 23, 2026:
- Copilot: https://raw.githubusercontent.com/primer/octicons/main/icons/copilot-24.svg
  (GitHub Primer Octicons, the Copilot mark used across GitHub)
- Grok: https://raw.githubusercontent.com/lobehub/lobe-icons/master/packages/static-svg/icons/grok.svg
  (the xAI Grok mark; `currentColor` fill set to black, path unchanged)

Source files are preserved. PNGs are rasterized without recoloring, cropping or
distortion. SVG derivatives use a 128px square bounding size. Unknown worker types
use the worker initial; never infer provider identity from a model/display name.

## Theme variants

Copilot and Grok use black marks in light themes (`*-light.png`) and white
marks in dark themes (`*-dark.png`), including live theme changes. Bundled
from `@lobehub/icons-static-png` 2.2.0 on October 24, 2026:
https://registry.npmjs.org/@lobehub/icons-static-png/-/icons-static-png-2.2.0.tgz

Upstream files: `light/githubcopilot.png`, `dark/githubcopilot.png`,
`light/grok.png`, and `dark/grok.png`. PNGs are copied without modification.
Source project and license: https://github.com/lobehub/lobe-icons (MIT;
brand marks remain the property of their respective owners).
The upstream MIT notice is bundled in `LOBE_ICONS_LICENSE.txt`.
Connect and Profile Lab use a theme surface behind these marks.
