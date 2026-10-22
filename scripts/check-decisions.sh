#!/usr/bin/env bash
#
# Checks the public decisions log for the two things that are easy to promise
# and easy to skip: that every entry states what it cost, and that every
# decision which has been made has an entry at all.
#
# Both halves fail the script rather than merely reporting.
#
# The second half does not try to match an entry to a question by title — an
# entry's title is prose and a question's is a question, and guessing pairs
# would either miss them or invent them. It counts instead: a phase that has
# answered N design questions must have added at least N entries to the log
# since the phase began. That is a floor rather than a proof, and it is enough,
# because the way this has actually failed twice is entries not being written at
# all rather than being written and mismatched.
#
# Why this exists. Two phases in a row promised to append a decision the moment
# an alternative was rejected, and two phases in a row failed: once by losing a
# decision made before the work, once by parking it correctly and never moving
# it into the public log when the implementing task landed. Both phases had the
# reminder. Neither had a check.
#
# Usage:
#   scripts/check-decisions.sh
#       audit the public log only
#   scripts/check-decisions.sh <spec-dir>
#       also list that phase's answered and open questions
#   scripts/check-decisions.sh <spec-dir> <git-ref>
#       also require one new entry per answered question, counting entries
#       added since <git-ref> — the commit the phase started from
#
# Exit status: 0 if every check passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO_ROOT/docs/decisions.md"
SPEC_DIR="${1:-}"
BASE_REF="${2:-}"

# The log as it stood at the baseline, so entries added since can be counted.
# Written to a temporary file rather than passed inline because it is large.
BASE_LOG=""
if [[ -n "$BASE_REF" ]]; then
  BASE_LOG="$(mktemp)"
  trap 'rm -f "$BASE_LOG"' EXIT
  if ! git -C "$REPO_ROOT" show "$BASE_REF:docs/decisions.md" > "$BASE_LOG" 2>/dev/null; then
    echo "cannot read docs/decisions.md at ref '$BASE_REF'" >&2
    exit 1
  fi
fi

if [[ ! -f "$LOG" ]]; then
  echo "no decisions log at $LOG" >&2
  exit 1
fi

python3 - "$LOG" "$SPEC_DIR" "$BASE_LOG" "$BASE_REF" <<'PY'
import re, sys, pathlib

log_path, spec_dir, base_log, base_ref = sys.argv[1:5]
text = pathlib.Path(log_path).read_text()


def titles(blob):
    return [c.split('\n', 1)[0].strip()
            for c in re.split(r'^## ', blob, flags=re.M)[1:]]

# Entries are second-level headings. The preamble before the first one is not
# an entry.
chunks = re.split(r'^## ', text, flags=re.M)[1:]
entries = [(c.split('\n', 1)[0].strip(), c) for c in chunks]

shortfall = []

print()
print("=" * 72)
print("DECISIONS LOG — every entry must state what it cost")
print("=" * 72)

missing = []
for i, (title, body) in enumerate(entries, 1):
    ok = 'Accepted cost' in body
    if not ok:
        missing.append(title)
    print("  %s %2d. %s" % ("   " if ok else "NO ", i, title))

print()
print("  %d entries, %d without a stated cost" % (len(entries), len(missing)))

if spec_dir:
    design = pathlib.Path(spec_dir) / 'design.md'
    if not design.is_file():
        print()
        print("  (no design.md under %s — skipping the comparison)" % spec_dir)
    else:
        dtext = design.read_text()
        print()
        print("=" * 72)
        print("DECISIONS MADE IN %s" % spec_dir.rstrip('/').split('/')[-1])
        print("=" * 72)
        qs = list(re.finditer(r'^### (Q\d+[a-z]?): (.+)$', dtext, re.M))
        answered, open_ = [], []
        for n, m in enumerate(qs):
            start = m.end()
            end = qs[n + 1].start() if n + 1 < len(qs) else len(dtext)
            (answered if 'Answered' in dtext[start:end] else open_).append(
                (m.group(1), m.group(2)))
        for tag, label in answered:
            print("  ANSWERED  %-4s %s" % (tag, label))
        for tag, label in open_:
            print("  open      %-4s %s" % (tag, label))
        print()
        print("  %d answered, %d still open." % (len(answered), len(open_)))

        if base_log:
            before = set(titles(pathlib.Path(base_log).read_text()))
            added = [t for t in titles(text) if t not in before]
            print()
            print("=" * 72)
            print("ENTRIES ADDED SINCE %s" % base_ref)
            print("=" * 72)
            for a in added:
                print("    %s" % a)
            if not added:
                print("    (none)")
            print()
            print("  %d questions answered, %d entries added."
                  % (len(answered), len(added)))
            if len(added) < len(answered):
                shortfall.append(
                    "%d answered question(s) with no corresponding new entry"
                    % (len(answered) - len(added)))
            else:
                print("  Floor met. Still check each pair by eye: a matching")
                print("  count is not a matching set.")
        else:
            print()
            print("  No baseline ref given, so nothing was verified about")
            print("  whether these have entries. Pass the commit the phase")
            print("  started from as a second argument to check that.")

# Decisions parked for a later phase. Listed on every run because the way this
# failed in Phase 2 was a decision being parked correctly and then never moved
# into the public log when the task that implemented it landed. A queue nobody
# looks at is the same as no queue.
parked = pathlib.Path('specs/carried-forward.md')
if parked.is_file():
    pending = [ti for ti, body in
               ((c.split('\n', 1)[0].strip(), c)
                for c in re.split(r'^## ', parked.read_text(), flags=re.M)[1:])
               if 'landed' not in body.lower()]
    print()
    print("=" * 72)
    print("PARKED, NOT YET IN THE PUBLIC LOG")
    print("=" * 72)
    for ti in pending:
        print("    %s" % ti)
    if not pending:
        print("    (none)")

print()
failed = False
if missing:
    failed = True
    print("FAIL — these entries do not say what they cost:")
    for m in missing:
        print("  - %s" % m)
    print()
if shortfall:
    failed = True
    print("FAIL — the log is behind the decisions that have been made:")
    for s in shortfall:
        print("  - %s" % s)
    print("  Append an entry per decision, each with an accepted cost.")
    print()
if failed:
    sys.exit(1)
print("PASS — every entry states a cost, and the log is not behind.")
print()
PY
