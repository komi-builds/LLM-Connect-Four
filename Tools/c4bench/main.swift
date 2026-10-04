import Foundation

// c4bench: run benchmarks and write reports (§5.5). See CLI.swift for the commands.
exit(await CLI.main(Array(CommandLine.arguments.dropFirst())))
