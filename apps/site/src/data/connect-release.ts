export interface ConnectReleaseTarget {
  readonly platform: "macos" | "windows" | "linux";
  readonly label: string;
  readonly architectures: readonly string[];
  readonly installSummary: string;
  readonly downloadUrl: string;
}

export interface ConnectReleaseManifest {
  readonly productName: string;
  readonly targets: readonly ConnectReleaseTarget[];
}

/**
 * Static distribution metadata. Keep installer URLs here so product surfaces
 * consume one release manifest instead of carrying independent links.
 */
export const connectRelease: ConnectReleaseManifest = {
  productName: "Syntila Connect",
  targets: [
    {
      platform: "macos",
      label: "macOS",
      architectures: ["Apple Silicon", "Intel"],
      installSummary:
        "Connect release for macOS",
      downloadUrl: "https://github.com/nohainc/syntila/releases/latest",
    },
    {
      platform: "windows",
      label: "Windows",
      architectures: ["x64"],
      installSummary:
        "Connect release for Windows",
      downloadUrl: "https://github.com/nohainc/syntila/releases/latest",
    },
    {
      platform: "linux",
      label: "Linux",
      architectures: ["x64", "arm64"],
      installSummary: "Connect release for Linux",
      downloadUrl: "https://github.com/nohainc/syntila/releases/latest",
    },
  ],
};
