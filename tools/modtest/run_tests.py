"""Run every mod test suite against a synthetic UE4SS world. No game required.

    python -m pip install lupa
    python tools/modtest/run_tests.py
    python tools/modtest/run_tests.py cenoclip          # one suite
    python tools/modtest/run_tests.py --list
    python tools/modtest/run_tests.py --quiet           # only failures
    python tools/modtest/run_tests.py cenoclip --compare old/main.lua

Each file in tests/ is a suite. It gets a fresh Lua runtime, so one suite
cannot leak globals, keybinds or a loaded mod into the next -- which matters
because a UE4SS mod registers its binds at load time and cannot be loaded twice
into the same world.

Exit code is the number of failed checks, so this drops straight into any
CI or pre-commit hook.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
MODTEST = Path(__file__).resolve().parent
TESTS = MODTEST / "tests"


def run_suite(path: Path, quiet: bool, compare: Path | None = None) -> tuple[int, int, str]:
    """Returns (failed, passed, output)."""
    import lupa

    lua = lupa.LuaRuntime(unpack_returned_tuples=True)

    # So a suite can `require("ue4ss_mock")` and `require("fixtures")`, and
    # address the repo without hardcoding anyone's checkout path.
    lua.globals().MODTEST_ROOT = ROOT.as_posix()
    # Suites that support A/B run their comparison section when this is set.
    if compare is not None:
        lua.globals().MODTEST_COMPARE = compare.as_posix()
    lua.execute(f'package.path = "{MODTEST.as_posix()}/?.lua;" .. package.path')

    lines: list[str] = []
    lua.globals().print = lambda *args: lines.append(
        "\t".join("" if a is None else str(a) for a in args)
    )

    suite = lua.execute(f'return dofile("{path.as_posix()}")')
    if suite is None:
        return 1, 0, f"{path.name}: suite returned nothing (missing `return suite`?)"

    failed = int(suite.finish(suite))
    passed = int(suite.passed)
    return failed, passed, "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("suites", nargs="*", help="suite names (default: all)")
    parser.add_argument("--list", action="store_true", help="list suites and exit")
    parser.add_argument("--quiet", action="store_true", help="print only failing suites")
    parser.add_argument("--compare", type=Path, default=None, metavar="MAIN_LUA",
                        help="a second main.lua to A/B against; suites that "
                             "support it run their comparison section")
    args = parser.parse_args()

    if args.compare is not None and not args.compare.is_file():
        print(f"not found: {args.compare}", file=sys.stderr)
        return 2

    try:
        import lupa  # noqa: F401
    except ImportError:
        print("lupa is required: python -m pip install lupa", file=sys.stderr)
        return 2

    available = sorted(TESTS.glob("*.lua"))
    if args.list:
        for path in available:
            print(f"  {path.stem}")
        return 0

    if args.suites:
        wanted = {name.lower() for name in args.suites}
        selected = [p for p in available if p.stem.lower() in wanted]
        missing = wanted - {p.stem.lower() for p in selected}
        if missing:
            print(f"no such suite: {', '.join(sorted(missing))}", file=sys.stderr)
            print(f"available: {', '.join(p.stem for p in available)}", file=sys.stderr)
            return 2
    else:
        selected = available

    if not selected:
        print(f"no suites found in {TESTS}", file=sys.stderr)
        return 2

    total_failed = total_passed = 0
    summaries = []

    for path in selected:
        failed, passed, output = run_suite(path, args.quiet, args.compare)
        total_failed += failed
        total_passed += passed
        if output and (not args.quiet or failed):
            print(output)
            print()
        summaries.append((path.stem, failed, passed))

    print("=" * 60)
    for name, failed, passed in summaries:
        mark = "FAIL" if failed else "ok  "
        print(f"  {mark}  {name:<20} {passed:>3} passed, {failed} failed")
    print("=" * 60)
    print(f"  {total_passed} checks passed, {total_failed} failed")

    return total_failed


if __name__ == "__main__":
    raise SystemExit(main())
