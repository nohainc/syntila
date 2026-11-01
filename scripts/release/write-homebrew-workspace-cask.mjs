#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required.`);
  return value;
};

const version = required("VERSION");
const sha256 = required("SHA256");
const output = required("OUTPUT");

if (!/^\d+\.\d+\.\d+$/.test(version)) {
  throw new Error("VERSION must be X.Y.Z.");
}
if (!/^[a-f0-9]{64}$/i.test(sha256)) {
  throw new Error("SHA256 must be a 64-character hexadecimal digest.");
}

mkdirSync(dirname(output), { recursive: true });
writeFileSync(
  output,
  `cask "syntila-workspace" do
  version "${version}"
  sha256 "${sha256.toLowerCase()}"

  url "https://github.com/nohainc/syntila/releases/download/workspace-macos-v#{version}/Syntila-Workspace-#{version}-macos.zip"
  name "Syntila Workspace"
  desc "Workspace GUI, CLI, and worker engine"
  homepage "https://github.com/nohainc/syntila"

  depends_on macos: ">= :sonoma"

  app "syntila/Syntila Workspace.app"
  artifact "syntila", target: "#{HOMEBREW_PREFIX}/lib/syntila-workspace"
  binary "#{HOMEBREW_PREFIX}/lib/syntila-workspace/syntila", target: "syntila"

  caveats <<~EOS
    The Workspace service is not installed or started automatically.
    Run \`syntila service install\` when ready, then \`syntila service start\`.
    After an upgrade, restart a running service with \`syntila service restart\`.
  EOS
end
`,
);
