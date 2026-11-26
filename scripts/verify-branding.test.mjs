import { mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  CANONICAL_SVG_MASTERS,
  verify3DArtworkIsolation,
  verifyBrandingHashSync,
  verifyBrandingSystem,
  verifyCanonicalSvgMasters,
  verifyNoHardcodedBrandColors,
  verifyRequiredGeneratedIcons,
} from "./verify-branding.mjs";

describe("Repository Branding CI Enforcement", () => {
  const rootDir = process.cwd();

  it("passes all branding verifications against current repository state", () => {
    const violations = verifyBrandingSystem(rootDir);
    expect(violations).toEqual([]);
  });

  describe("Canonical Vector Masters Verification", () => {
    it("accepts only wrappers embedding the exact approved source", () => {
      const tempDir = join(tmpdir(), `syntila-approved-source-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "assets/branding"), { recursive: true });
        const source = readFileSync(
          join(rootDir, "assets/branding/syntila_source.png"),
        );
        writeFileSync(
          join(tempDir, "assets/branding/syntila_source.png"),
          source,
        );
        for (const svg of CANONICAL_SVG_MASTERS) {
          writeFileSync(
            join(tempDir, "assets/branding", svg),
            `<svg><image href="data:image/png;base64,${source.toString("base64")}"/></svg>`,
          );
        }
        expect(verifyCanonicalSvgMasters(tempDir)).toEqual([]);
        writeFileSync(
          join(tempDir, "assets/branding/syntila_source.png"),
          "different source",
        );
        expect(verifyCanonicalSvgMasters(tempDir).length).toBeGreaterThan(0);
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });

    it("validates that all canonical SVG masters exist and contain valid vector paths", () => {
      const violations = verifyCanonicalSvgMasters(rootDir);
      expect(violations).toEqual([]);
    });

    it("rejects SVGs with embedded rasters or base64 data URIs", () => {
      const tempDir = join(tmpdir(), `syntila-test-raster-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "assets/branding"), { recursive: true });
        for (const svg of CANONICAL_SVG_MASTERS) {
          if (svg === "syntila_mark.svg") {
            writeFileSync(
              join(tempDir, "assets/branding", svg),
              `<svg><path d="M0 0"/><image href="data:image/png;base64,iVBORw0KGgo="/></svg>`,
            );
          } else {
            writeFileSync(
              join(tempDir, "assets/branding", svg),
              `<svg viewBox="0 0 100 100"><path d="M10 10 L90 90"/></svg>`,
            );
          }
        }

        const violations = verifyCanonicalSvgMasters(tempDir);
        expect(violations.length).toBeGreaterThan(0);
        expect(violations[0]).toContain("Vector purity violation");
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });

    it("rejects SVGs without path or vector geometry definitions", () => {
      const tempDir = join(tmpdir(), `syntila-test-nopath-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "assets/branding"), { recursive: true });
        for (const svg of CANONICAL_SVG_MASTERS) {
          if (svg === "syntila_mark.svg") {
            writeFileSync(
              join(tempDir, "assets/branding", svg),
              `<svg viewBox="0 0 100 100"><rect width="10" height="10"/></svg>`,
            );
          } else {
            writeFileSync(
              join(tempDir, "assets/branding", svg),
              `<svg viewBox="0 0 100 100"><path d="M10 10 L90 90"/></svg>`,
            );
          }
        }

        const violations = verifyCanonicalSvgMasters(tempDir);
        expect(violations.length).toBeGreaterThan(0);
        expect(violations[0]).toContain("Vector geometry missing");
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });
  });

  describe("Required Generated Icons Verification", () => {
    it("confirms all canonical PNGs and client app derivatives exist", () => {
      const violations = verifyRequiredGeneratedIcons(rootDir);
      expect(violations).toEqual([]);
    });

    it("flags missing generated icon files", () => {
      const tempDir = join(tmpdir(), `syntila-test-missing-png-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "assets/branding"), { recursive: true });
        // Only create 1 png
        writeFileSync(
          join(tempDir, "assets/branding/syntila_logo.png"),
          "mock",
        );

        const violations = verifyRequiredGeneratedIcons(tempDir);
        expect(violations.length).toBeGreaterThan(0);
        expect(
          violations.some((v) => v.includes("Canonical master PNG missing")),
        ).toBe(true);
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });
  });

  describe("Branding Hash Synchronization & Drift Detection", () => {
    it("confirms 100% hash synchronization across canonical and client asset trees", () => {
      const violations = verifyBrandingHashSync(rootDir);
      expect(violations).toEqual([]);
    });

    it("flags drift when target file content diverges from canonical master", () => {
      const tempDir = join(tmpdir(), `syntila-test-drift-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "assets/branding"), { recursive: true });
        mkdirSync(join(tempDir, "apps/app/assets/branding"), {
          recursive: true,
        });

        const canonicalContent = '<svg><path d="M10 10"/></svg>';
        const modifiedContent = '<svg><path d="M20 20"/></svg>';

        writeFileSync(
          join(tempDir, "assets/branding/syntila_mark.svg"),
          canonicalContent,
        );
        writeFileSync(
          join(tempDir, "apps/app/assets/branding/syntila_mark.svg"),
          modifiedContent,
        );

        const violations = verifyBrandingHashSync(tempDir);
        expect(violations.length).toBe(1);
        expect(violations[0]).toContain(
          "Branding hash mismatch (drift detected)",
        );
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });
  });

  describe("3D Marketing Artwork Isolation", () => {
    it("verifies 3D artwork is absent from production runtime asset directories", () => {
      const violations = verify3DArtworkIsolation(rootDir);
      expect(violations).toEqual([]);
    });

    it("flags 3D artwork placed inside assets/branding/", () => {
      const tempDir = join(tmpdir(), `syntila-test-3d-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "assets/branding"), { recursive: true });
        writeFileSync(
          join(tempDir, "assets/branding/syntila_mark_3d.png"),
          "fake-3d-bytes",
        );

        const violations = verify3DArtworkIsolation(tempDir);
        expect(violations.length).toBe(1);
        expect(violations[0]).toContain("3D artwork isolation violation");
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });
  });

  describe("Hardcoded Brand Color Detection", () => {
    it("verifies zero hardcoded brand purple colors exist in client applications", () => {
      const violations = verifyNoHardcodedBrandColors(rootDir);
      expect(violations).toEqual([]);
    });

    it("flags direct hardcoded Color(0xff5e4bd8) in application code", () => {
      const tempDir = join(tmpdir(), `syntila-test-hardcolor-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "apps/app/lib"), { recursive: true });
        writeFileSync(
          join(tempDir, "apps/app/lib/sample_widget.dart"),
          `import 'package:flutter/material.dart';
class MyWidget extends StatelessWidget {
  Widget build(BuildContext context) => Container(color: const Color(0xff5e4bd8));
}`,
        );

        const violations = verifyNoHardcodedBrandColors(tempDir);
        expect(violations.length).toBe(1);
        expect(violations[0]).toContain("Hardcoded brand color detected");
        expect(violations[0]).toContain("Primary Brand Purple");
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });

    it("flags direct hardcoded hex code #B8A9FE in application code", () => {
      const tempDir = join(tmpdir(), `syntila-test-hardhex-${Date.now()}`);
      try {
        mkdirSync(join(tempDir, "apps/connect_gui/lib"), { recursive: true });
        writeFileSync(
          join(tempDir, "apps/connect_gui/lib/sample_panel.dart"),
          `const brandColor = '#b8a9fe';`,
        );

        const violations = verifyNoHardcodedBrandColors(tempDir);
        expect(violations.length).toBe(1);
        expect(violations[0]).toContain("Hardcoded brand color detected");
        expect(violations[0]).toContain("Primary Foreground Dark");
      } finally {
        rmSync(tempDir, { recursive: true, force: true });
      }
    });
  });
});
