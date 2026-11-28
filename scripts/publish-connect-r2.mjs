#!/usr/bin/env node
import { publishConnect, releaseClient } from "./internal/release-r2.mjs";
const [platform, version, commit, ...paths] = process.argv.slice(2);
try {
  const bucket = process.env.SYNTILA_RELEASE_R2_BUCKET || "syntila-releases";
  await publishConnect({
    client: releaseClient(),
    bucket,
    platform,
    version,
    commit,
    paths,
  });
  console.log(`Published Connect ${version} (${platform}) to R2.`);
} catch (error) {
  console.error(`R2 release failed: ${error.message}`);
  process.exitCode = 1;
}
