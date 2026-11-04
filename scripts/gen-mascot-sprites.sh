#!/bin/zsh
# Regenerate the T2 mascot sprite strips (spec: animation-performance.md).
#
# Any change to a mascot view's idle/work scenes MUST be followed by this
# script, or the bundled strips go stale (playback shows the old animation).
# Alert scenes stay live-rendered and need no strips.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Sources/CodeIsland/Resources/mascot-sprites"
SOURCES="${MASCOT_SPRITE_SOURCES:-claude,codex,grok,gemini,cursor,trae,traecn,traecli,copilot,qoder,qoder-cli,droid,codebuddy,stepfun,opencode,qwen,antigravity,workbuddy,hermes,openclaw,kiro,kimi,pi,cline,aiwork,zcode,minimax}"

echo "Rendering sprite strips for: $SOURCES"
rm -rf "$OUT"
MASCOT_SPRITE_DIR="$PWD/$OUT" MASCOT_SPRITE_SOURCES="$SOURCES" \
  swift test --filter MascotRenderHarness/testRenderSpriteStrips 2>&1 | grep "strip:"

echo
echo "Done: $(ls "$OUT" | grep -c png) strips, $(du -sh "$OUT" | cut -f1) total."
echo "Commit the Resources/mascot-sprites directory together with the view change."
