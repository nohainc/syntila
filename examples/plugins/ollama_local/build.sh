#!/usr/bin/env bash
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SOURCE/../../.." && pwd)"
MODEL="${1:-llama3.2:3b}"
OLLAMA_BINARY="$(command -v ollama)"
DEST="$ROOT/dist/plugins/ollama-local"
mkdir -p "$DEST/bin"
cd "$SOURCE"
dart pub get
dart compile exe bin/main.dart -DOLLAMA_MODEL="$MODEL" -DOLLAMA_EXECUTABLE="$OLLAMA_BINARY" -o "$DEST/bin/ollama-local"
node --input-type=module - "$DEST" <<'JS'
import {writeFileSync} from 'node:fs';
const platform = {darwin:'darwin',linux:'linux',win32:'windows'}[process.platform];
const arch = {arm64:'arm64',x64:'x64'}[process.arch];
if (!platform || !arch) throw Error('Unsupported build host');
writeFileSync(`${process.argv[2]}/plugin.json`, JSON.stringify({
 schemaVersion:1, pluginId:'ollama-local', version:'1.0.0',
 displayName:'Ollama Local', description:'Text generation with a pinned local Ollama model. No file editing or tool execution.',
 author:{name:'Local plugin author'}, protocol:{min:'1.0',max:'1.0'},
 artifacts:{[`${platform}-${arch}`]:{command:'bin/ollama-local',args:[],sha256:'0'.repeat(64),size:1}},
 capabilities:{progress:true},
 access:{workRoot:'read',network:{mode:'declared',hosts:['127.0.0.1']},subprocess:true,env:[]}
}, null, 2)+'\n');
JS
dart run syntila_plugin_sdk:pack "$DEST"
printf 'Plugin package: %s\n' "$DEST"
