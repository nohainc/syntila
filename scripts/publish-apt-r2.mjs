#!/usr/bin/env node
import { publishApt } from "./internal/publish-apt-r2.mjs";
import { releaseClient } from "./internal/release-r2.mjs";
const [repo, version] = process.argv.slice(2);
try {
  await publishApt({
    client: releaseClient(),
    bucket: process.env.SYNTILA_RELEASE_R2_BUCKET || "syntila-releases",
    repo,
    version,
  });
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
