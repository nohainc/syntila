export interface WorkspaceReleaseTarget {
  readonly platform: "macos" | "windows" | "linux";
  readonly label: string;
  readonly architectures: readonly string[];
  readonly installSummary: string;
  readonly downloadUrl: string;
}

export interface WorkspaceReleaseManifest {
  readonly productName: string;
  readonly version: string;
  readonly targets: readonly WorkspaceReleaseTarget[];
}

/**
 * Static distribution metadata. Keep installer URLs here so product surfaces
 * consume one release manifest instead of carrying independent links.
 */
export const workspaceRelease: WorkspaceReleaseManifest = {
  productName: "Syntila Workspace",
  version: "1.0.18",
  targets: [
    {
      platform: "macos",
      label: "macOS",
      architectures: ["Apple Silicon", "Intel"],
      installSummary:
        "Signed release bundle or Homebrew cask (brew install --cask nohainc/tap/syntila-workspace)",
      downloadUrl: "https://github.com/nohainc/conclave/releases/latest",
    },
    {
      platform: "windows",
      label: "Windows",
      architectures: ["x64"],
      installSummary: "Per-user logon service and syntila CLI release archive",
      downloadUrl: "https://github.com/nohainc/conclave/releases/latest",
    },
    {
      platform: "linux",
      label: "Linux",
      architectures: ["x64", "arm64"],
      installSummary:
        "Signed APT repository (syntila) or standalone release archive",
      downloadUrl: "https://github.com/nohainc/conclave/releases/latest",
    },
  ],
};
