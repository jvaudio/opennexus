#!/bin/zsh
# The repository's lint, run by CI: Swift formatting, then the brand checks.
#
#   scripts/lint.sh
#
# The brand checks fail if the old "Triad" mark comes back (its name, or either version of
# its path), or if the document icon is out of date with brand/macos.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
failed=0

swift format lint --strict -r Sources Tests App/OpenNexus || failed=1

# The only files allowed to name the old mark: the kit's own brief, the plan that
# inventoried it, and this script.
if git grep --untracked -n -I -i -E 'Triad|M12 32 L22 12|M14 30 L22 14' -- . \
    ':!brand/CLAUDE_CODE_PROMPT.md' ':!docs/plans/brand-aperture.md' ':!scripts/lint.sh'; then
    print -u2 "lint: the old Triad mark is back (above); use the Aperture assets in brand/"
    failed=1
fi

scripts/build-icons.sh --check || failed=1

exit $failed
