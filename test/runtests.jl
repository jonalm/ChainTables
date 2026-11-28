using ChainTables: ChainTables
using ParallelTestRunner: filter_tests!, find_tests, parse_args, runtests

testsuite = find_tests(@__DIR__)
filter!(t -> !startswith(first(t), r"fixtures/|live/"), testsuite)
args = parse_args(ARGS)
filter_tests!(testsuite, args) && filter!(t -> !startswith(first(t), "perf/"), testsuite)
runtests(ChainTables, args; testsuite)
