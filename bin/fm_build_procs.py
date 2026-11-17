"""The build and test process classes Firstmate treats as a worker's own leftovers.

bin/fm-fleet-alarm.py counts orphaned processes of these classes, and
bin/fm-proc-family.py stops a process that left a worker's session only when it
is one of them. Each pattern matches a full command line (argv joined by spaces).
"""
import re

BUILD_TEST_ARGS = (
    # dotnet build and test processes, with or without the dotnet host in front.
    re.compile(r'(?:^|[\s/])(?:MSBuild|VBCSCompiler|testhost)(?:\.dll|\.exe)?(?=\s|$)'),
    # node running a test runner.
    re.compile(r'^(?:\S*/)?node(?:\.exe)?\s.*[/\s@](?:vitest|jest|playwright|playwright-core)(?=[/\s.]|$)'),
    # a browser Playwright launched from its own cache or profile directory.
    re.compile(r'ms-playwright|playwright_(?:chromium|firefox|webkit)dev_profile'),
)


def is_build_or_test(args):
    """True when the command line belongs to one of the build or test classes."""
    return bool(args) and any(pattern.search(args) for pattern in BUILD_TEST_ARGS)
