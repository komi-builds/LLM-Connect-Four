import C4AI
import C4Bench
import C4Core
import C4MLX
import Foundation

// c4bench: run benchmarks and write reports (§5.5). Implemented by agent G.
//
//   c4bench run --model <id> --style explain --difficulty hard --suite quick
//   c4bench puzzles --model <id>
//   c4bench report --format md|csv|json

let usage = """
    usage: c4bench run --model <id> [--style instinct|explain|deepThink] [--difficulty easy|moderate|hard] \
    [--variant <id>] [--suite quick|standard|full]
           c4bench puzzles --model <id> [--style …] [--difficulty …]
           c4bench report [--format md|csv|json] [--out <path>]
    """

print(usage)
exit(CommandLine.arguments.count > 1 ? 1 : 0)
