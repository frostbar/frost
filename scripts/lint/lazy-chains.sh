#!/usr/bin/env bash
# Fails on lazy sequence chains in the tracked Swift sources: `.lazy` followed by `.map`, `.compactMap`, `.filter` or
# `.flatMap` (also when the chain continues on the next line), unless the line with `.lazy` carries the marker
#
#     // lint: lazy-ok (<reason>)
#
# with a non-empty reason.
#
# Why: a lazy chain runs its closures whenever an element is accessed, not once per element, so a closure may run more
# than once for the same element: `first` on a lazy `compactMap` runs it twice for the element it returns, and so do
# `isEmpty` followed by an iteration, `count`, or iterating twice. With a closure that has side effects, that is a bug.
# 0.3.1 crashed at launch on exactly this: `earlierKeys.lazy.compactMap({ diskCache.migrate(...) }).first` moved the
# cached files on the first call, found nothing on the second, and the runtime force-unwrapped nil.
#
# Instead, use a plain loop, an eager chain (drop `.lazy`), or a lazy view without closures (`joined()`). Mark a lazy
# chain only when its closures are pure and the laziness is worth it, and say why in the reason.
#
# Runs in CI (.github/workflows/ci.yml, Lint job) and locally with `make lint`; works from anywhere in the repository.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

git ls-files -z -- '*.swift' | perl -e '
    use strict;
    use warnings;
    my $failed = 0;
    my @files = do { local $/ = "\0"; map { chomp; $_ } <STDIN> };
    for my $file (@files) {
        open(my $handle, "<", $file) or die "$file: $!\n";
        my $text = do { local $/; <$handle> };
        close $handle;
        while ($text =~ /\.lazy\b\s*\.(map|compactMap|filter|flatMap)\b/g) {
            my $start = $-[0];
            my $operator = $1;
            my $line = 1 + (substr($text, 0, $start) =~ tr/\n//);
            my $lineStart = rindex($text, "\n", $start) + 1;
            my $lineEnd = index($text, "\n", $start);
            $lineEnd = length($text) if $lineEnd < 0;
            my $content = substr($text, $lineStart, $lineEnd - $lineStart);
            next if $content =~ m{//\s*lint:\s*lazy-ok\s*\(\s*[^)\s][^)]*\)};
            $failed = 1;
            my $message = "lazy .$operator chain: its closures may run more than once per element. Use a loop or an "
                . "eager chain, or mark the line with // lint: lazy-ok (<reason>) (see scripts/lint/lazy-chains.sh)";
            if ($ENV{GITHUB_ACTIONS}) {
                print "::error file=$file,line=${line}::$message\n";
            } else {
                print "$file:$line: $message\n";
            }
        }
    }
    exit $failed;
'
