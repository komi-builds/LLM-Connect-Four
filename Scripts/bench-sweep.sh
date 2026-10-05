#!/bin/zsh
# The benchmark sweep behind LEADERBOARD.md, in stages. Every stage is resumable: run the
# same stage again and finished games and puzzles are skipped.
#
#   Scripts/bench-sweep.sh breadth     # Quick: every model, Instinct and Explain, Moderate
#   Scripts/bench-sweep.sh prompts     # Quick: every prompt variant, default model, Instinct
#   Scripts/bench-sweep.sh depth       # Standard: default model, Explain, all difficulties
#   Scripts/bench-sweep.sh thinking    # Quick: Deep think on the models that can think
#   Scripts/bench-sweep.sh report      # writes LEADERBOARD.md
#
# Data goes to ~/Library/Application Support/LLMConnectFour/bench/ (override with DIR=...).
# Close other apps: one model is loaded at a time, up to about 5 GB for Qwen3 8B.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=Release SCHEME=c4bench Scripts/xc.sh build > /dev/null
bench=build/DerivedData/Build/Products/Release/c4bench
dir_args=()
[[ -n "${DIR:-}" ]] && dir_args=(--dir "$DIR")

default_model="mlx-community/Qwen3-4B-Instruct-2507-4bit"
all_models=(
  mlx-community/Qwen3-4B-Instruct-2507-4bit
  mlx-community/Qwen3-1.7B-4bit
  mlx-community/Llama-3.2-3B-Instruct-4bit
  mlx-community/gemma-3-text-4b-it-4bit
  mlx-community/Qwen3.5-4B-4bit
  mlx-community/Qwen3-4B-Thinking-2507-4bit
  mlx-community/Qwen3-8B-4bit
)
thinking_models=(
  mlx-community/Qwen3-1.7B-4bit
  mlx-community/Qwen3-4B-Thinking-2507-4bit
  mlx-community/Qwen3-8B-4bit
)

models_args() { for m in "$@"; do print -n -- "--model $m "; done }

case "${1:-}" in
  breadth)
    $bench run ${=$(models_args $all_models)} --style instinct --style explain \
      --difficulty moderate --suite quick $dir_args --quiet
    ;;
  prompts)
    variants=(combined grid columns combined-nofs combined-nohist combined-nofs-nohist
      grid-nofs columns-nofs)
    $bench run --model $default_model --style instinct --difficulty moderate \
      ${=$(for v in $variants; do print -n -- "--variant $v "; done)} --suite quick $dir_args --quiet
    ;;
  depth)
    $bench run --model $default_model --style explain \
      --difficulty easy --difficulty moderate --difficulty hard --suite standard $dir_args --quiet
    ;;
  thinking)
    $bench run ${=$(models_args $thinking_models)} --style deepThink --difficulty moderate \
      --suite quick $dir_args --quiet
    ;;
  report)
    $bench report --format md --machine-filter $dir_args --out LEADERBOARD.md
    $bench report --format md --machine-filter $dir_args
    ;;
  *)
    sed -n 2,13p "$0"
    exit 1
    ;;
esac
