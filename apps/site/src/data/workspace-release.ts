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
        "Signed release bundle with the desktop app, or the Homebrew cask",
      downloadUrl: "https://github.com/nohainc/syntila/releases/latest",
    },
    {
      platform: "windows",
      label: "Windows",
      architectures: ["x64"],
      installSummary:
        "Release archive with the service and the syntila command",
      downloadUrl: "https://github.com/nohainc/syntila/releases/latest",
    },
    {
      platform: "linux",
      label: "Linux",
      architectures: ["x64", "arm64"],
      installSummary: "Signed APT package, or a standalone release archive",
      downloadUrl: "https://github.com/nohainc/syntila/releases/latest",
    },
  ],
};
