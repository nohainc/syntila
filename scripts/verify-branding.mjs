import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const CANONICAL_SVG_MASTERS = [
  "syntila_mark.svg",
  "syntila_mark_dark.svg",
  "syntila_mark_monochrome.svg",
  "syntila_mark_twotone.svg",
  "syntila_wordmark.svg",
  "syntila_wordmark_dark.svg",
  "syntila_logo.svg",
  "syntila_logo_dark.svg",
];

export const REQUIRED_CANONICAL_PNGS = [
  "syntila_logo.png",
  "syntila_logo_512.png",
  "syntila_logo_192.png",
  "syntila_logo_128.png",
  "syntila_email_logo.png",
  "syntila_logo_64.png",
  "syntila_logo_32.png",
  "syntila_logo_dark.png",
  "syntila_logo_dark_512.png",
  "syntila_logo_dark_192.png",
  "syntila_logo_dark_128.png",
  "syntila_logo_dark_64.png",
  "syntila_logo_dark_32.png",
];

export const MACOS_APP_ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024];

export const FORBIDDEN_BRAND_COLOR_PATTERNS = [
  {
    name: "Primary Brand Purple (#5E4BD8)",
    regex: /0x[fF]{2}5[eE]4[bB][dD]8|#5[eE]4[bB][dD]8\b/,
  },
  {
    name: "Primary Pressed Purple (#4937BD)",
    regex: /0x[fF]{2}4937[bB][dD]|#4937[bB][dD]\b/,
  },
  {
    name: "Primary Foreground Dark (#B8A9FE)",
    regex: /0x[fF]{2}[bB]8[aA]9[fF][eE]|#[bB]8[aA]9[fF][eE]\b/,
  },
  {
    name: "Primary Soft Light (#DEDCF4)",
    regex: /0x[fF]{2}[dD][eE][dD][cC][fF]4|#[dD][eE][dD][cC][fF]4\b/,
  },
  {
    name: "Primary Soft Dark (#231D47)",
    regex: /0x[fF]{2}231[dD]47|#231[dD]47\b/,
  },
  {
    name: "Navigation Selected (#302D4B)",
    regex: /0x[fF]{2}302[dD]4[bB]|#302[dD]4[bB]\b/,
  },
];

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function findFilesRecursive(dir, predicate) {
  if (!existsSync(dir)) return [];
  const results = [];
  const entries = readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...findFilesRecursive(fullPath, predicate));
    } else if (entry.isFile() && (!predicate || predicate(fullPath))) {
      results.push(fullPath);
    }
  }
  return results;
}

/**
 * 1. Verify Canonical Vector Masters (existence, pure vector geometry, no embedded rasters).
 */
export function verifyCanonicalSvgMasters(rootDir) {
  const violations = [];
  const canonicalDir = join(rootDir, "assets/branding");

  for (const svgName of CANONICAL_SVG_MASTERS) {
    const svgPath = join(canonicalDir, svgName);
    if (!existsSync(svgPath)) {
      violations.push(
        `Canonical SVG master missing: ${relative(rootDir, svgPath)}`,
      );
      continue;
    }

    const content = readFileSync(svgPath, "utf8");

    const sourcePath = join(canonicalDir, "syntila_source.png");
    const sourceDarkPath = join(canonicalDir, "syntila_source_dark.png");
    const matchesLightSource =
      existsSync(sourcePath) &&
      content.includes(
        `data:image/png;base64,${readFileSync(sourcePath).toString("base64")}`,
      );
    const matchesDarkSource =
      existsSync(sourceDarkPath) &&
      content.includes(
        `data:image/png;base64,${readFileSync(sourceDarkPath).toString("base64")}`,
      );
    const approvedRaster =
      (matchesLightSource || matchesDarkSource) &&
      (content.match(/<image\b/g) || []).length === 1;
    if (
      /data:image\/|<image\s|xlink:href="data:/i.test(content) &&
      !approvedRaster
    ) {
      violations.push(
        `Vector purity violation in ${relative(rootDir, svgPath)}: embedded raster or base64 data URI detected.`,
      );
    }

    if (!/<path|<defs|<use/i.test(content) && !approvedRaster) {
      violations.push(
        `Vector geometry missing in ${relative(rootDir, svgPath)}: no path or geometry definitions found.`,
      );
    }
  }

  return violations;
}

/**
 * 2. Verify all required generated icons exist across all client applications.
 */
export function verifyRequiredGeneratedIcons(rootDir) {
  const violations = [];
  const canonicalDir = join(rootDir, "assets/branding");

  // Canonical master PNGs
  for (const pngName of REQUIRED_CANONICAL_PNGS) {
    const pngPath = join(canonicalDir, pngName);
    if (!existsSync(pngPath)) {
      violations.push(
        `Canonical master PNG missing: ${relative(rootDir, pngPath)}`,
      );
    }
  }

  // Application asset sync targets
  const appTargets = ["apps/app", "apps/profile_lab"];
  for (const app of appTargets) {
    const destBrandingDir = join(rootDir, app, "assets/branding");
    for (const svgName of CANONICAL_SVG_MASTERS) {
      const p = join(destBrandingDir, svgName);
      if (!existsSync(p)) {
        violations.push(
          `Required app vector asset missing: ${relative(rootDir, p)}`,
        );
      }
    }
    for (const pngName of REQUIRED_CANONICAL_PNGS) {
      const p = join(destBrandingDir, pngName);
      if (!existsSync(p)) {
        violations.push(
          `Required app raster asset missing: ${relative(rootDir, p)}`,
        );
      }
    }
  }

  // Web PWA icons in apps/app/web
  const webDir = join(rootDir, "apps/app/web");
  const requiredWebFiles = [
    "syntila_logo.svg",
    "favicon.png",
    "icons/Icon-192.png",
    "icons/Icon-512.png",
    "icons/Icon-maskable-192.png",
    "icons/Icon-maskable-512.png",
  ];
  for (const file of requiredWebFiles) {
    const p = join(webDir, file);
    if (!existsSync(p)) {
      violations.push(
        `Required web app asset missing: ${relative(rootDir, p)}`,
      );
    }
  }

  // Landing site public branding
  const sitePublicDir = join(rootDir, "apps/site/public");
  const requiredSiteFiles = [
    "syntila_mark.svg",
    "syntila_mark_dark.svg",
    "syntila_mark_monochrome.svg",
    "syntila_logo.svg",
    "syntila_logo_dark.svg",
    "syntila_wordmark.svg",
    "syntila_wordmark_dark.svg",
    "syntila_logo.png",
    "syntila_logo_dark.png",
    "syntila_email_logo.png",
    "favicon.png",
    "favicon.svg",
  ];
  for (const file of requiredSiteFiles) {
    const p = join(sitePublicDir, file);
    if (!existsSync(p)) {
      violations.push(
        `Required landing site asset missing: ${relative(rootDir, p)}`,
      );
    }
  }

  // macOS AppIcon sets (Workspace is a headless service/CLI and has no app icon)
  for (const macosApp of ["apps/profile_lab"]) {
    const iconSetDir = join(
      rootDir,
      macosApp,
      "macos/Runner/Assets.xcassets/AppIcon.appiconset",
    );
    for (const size of MACOS_APP_ICON_SIZES) {
      const iconPath = join(iconSetDir, `app_icon_${size}.png`);
      if (!existsSync(iconPath)) {
        violations.push(
          `Required macOS AppIcon missing: ${relative(rootDir, iconPath)}`,
        );
      }
    }
  }

  return violations;
}

/**
 * 3. Verify branding copies match expected canonical SHA-256 hashes (zero drift).
 */
export function verifyBrandingHashSync(rootDir) {
  const violations = [];
  const canonicalDir = join(rootDir, "assets/branding");

  // Map of canonical file -> list of synchronized target copies
  const syncPairs = [];

  for (const app of ["apps/app", "apps/profile_lab"]) {
    for (const svgName of CANONICAL_SVG_MASTERS) {
      syncPairs.push({
        source: join(canonicalDir, svgName),
        target: join(rootDir, app, "assets/branding", svgName),
      });
    }
    for (const pngName of REQUIRED_CANONICAL_PNGS) {
      syncPairs.push({
        source: join(canonicalDir, pngName),
        target: join(rootDir, app, "assets/branding", pngName),
      });
    }
  }

  // Web & site aliases
  syncPairs.push(
    {
      source: join(canonicalDir, "syntila_logo.svg"),
      target: join(rootDir, "apps/app/web/syntila_logo.svg"),
    },
    {
      source: join(canonicalDir, "syntila_logo.svg"),
      target: join(rootDir, "apps/site/public/favicon.svg"),
    },
    {
      source: join(canonicalDir, "syntila_logo.svg"),
      target: join(rootDir, "apps/site/public/syntila_logo.svg"),
    },
    {
      source: join(canonicalDir, "syntila_logo_dark.svg"),
      target: join(rootDir, "apps/site/public/syntila_logo_dark.svg"),
    },
    {
      source: join(canonicalDir, "syntila_mark.svg"),
      target: join(rootDir, "apps/site/public/syntila_mark.svg"),
    },
    {
      source: join(canonicalDir, "syntila_mark_dark.svg"),
      target: join(rootDir, "apps/site/public/syntila_mark_dark.svg"),
    },
    {
      source: join(canonicalDir, "syntila_mark_monochrome.svg"),
      target: join(rootDir, "apps/site/public/syntila_mark_monochrome.svg"),
    },
    {
      source: join(canonicalDir, "syntila_wordmark.svg"),
      target: join(rootDir, "apps/site/public/syntila_wordmark.svg"),
    },
    {
      source: join(canonicalDir, "syntila_wordmark_dark.svg"),
      target: join(rootDir, "apps/site/public/syntila_wordmark_dark.svg"),
    },
    {
      source: join(canonicalDir, "syntila_logo_32.png"),
      target: join(rootDir, "apps/app/web/favicon.png"),
    },
    {
      source: join(canonicalDir, "syntila_logo_32.png"),
      target: join(rootDir, "apps/site/public/favicon.png"),
    },
    {
      source: join(canonicalDir, "syntila_logo.png"),
      target: join(rootDir, "apps/site/public/syntila_logo.png"),
    },
    {
      source: join(canonicalDir, "syntila_logo_dark.png"),
      target: join(rootDir, "apps/site/public/syntila_logo_dark.png"),
    },
  );

  for (const { source, target } of syncPairs) {
    if (!existsSync(source) || !existsSync(target)) continue;
    const sourceHash = sha256(readFileSync(source));
    const targetHash = sha256(readFileSync(target));
    if (sourceHash !== targetHash) {
      violations.push(
        `Branding hash mismatch (drift detected) between canonical master ${relative(
          rootDir,
          source,
        )} and ${relative(rootDir, target)}`,
      );
    }
  }

  return violations;
}

/**
 * 4. Verify 3D marketing artwork isolation (must never exist in canonical UI or runtime asset directories).
 */
export function verify3DArtworkIsolation(rootDir) {
  const violations = [];
  const prohibitedDirs = [
    join(rootDir, "assets/branding"),
    join(rootDir, "apps/app/assets"),
    join(rootDir, "apps/connect_gui/assets"),
    join(rootDir, "apps/profile_lab/assets"),
    join(rootDir, "apps/app/web"),
    join(rootDir, "apps/site/public"),
  ];

  for (const dir of prohibitedDirs) {
    if (!existsSync(dir)) continue;
    const files = findFilesRecursive(dir, (f) => /3d|syntila_mark_3d/i.test(f));
    for (const f of files) {
      violations.push(
        `3D artwork isolation violation: ${relative(
          rootDir,
          f,
        )} is in a production runtime asset path. 3D assets must be located strictly in 'marketing/'.`,
      );
    }
  }

  return violations;
}

/**
 * 5. Verify no direct hardcoded brand purple colors in Dart client application code.
 * (Components must consume SyntilaColors / SyntilaBrand tokens or Theme.of(context)).
 */
export function verifyNoHardcodedBrandColors(rootDir) {
  const violations = [];
  const appLibDirs = [
    join(rootDir, "apps/app/lib"),
    join(rootDir, "apps/connect_gui/lib"),
    join(rootDir, "apps/profile_lab/lib"),
  ];

  for (const dir of appLibDirs) {
    if (!existsSync(dir)) continue;
    const dartFiles = findFilesRecursive(dir, (f) => f.endsWith(".dart"));
    for (const file of dartFiles) {
      const content = readFileSync(file, "utf8");
      const lines = content.split("\n");

      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        // Ignore single-line comments
        if (line.trim().startsWith("//") || line.trim().startsWith("///"))
          continue;

        for (const { name, regex } of FORBIDDEN_BRAND_COLOR_PATTERNS) {
          if (regex.test(line)) {
            violations.push(
              `Hardcoded brand color detected in ${relative(
                rootDir,
                file,
              )}:${i + 1} (${name}). Use SyntilaColors tokens or Theme.of(context) instead of raw Color literal.`,
            );
          }
        }
      }
    }
  }

  return violations;
}

/**
 * Runs the complete repository branding validation.
 */
export function verifyBrandingSystem(rootDir) {
  const allViolations = [
    ...verifyCanonicalSvgMasters(rootDir),
    ...verifyRequiredGeneratedIcons(rootDir),
    ...verifyBrandingHashSync(rootDir),
    ...verify3DArtworkIsolation(rootDir),
    ...verifyNoHardcodedBrandColors(rootDir),
  ];

  return allViolations;
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const violations = verifyBrandingSystem(rootDir);

  if (violations.length > 0) {
    console.error(
      "=================================================================",
    );
    console.error(" Syntila Branding System Repository Enforcement Failed!");
    console.error(
      "=================================================================",
    );
    for (const violation of violations) {
      console.error(`- ${violation}`);
    }
    console.error(
      "=================================================================",
    );
    process.exit(1);
  }

  console.log(
    "Branding system check passed: canonical SVGs, approved source artwork, icon completeness, hash synchronization, 3D isolation, and zero hardcoded brand colors verified.",
  );
}
