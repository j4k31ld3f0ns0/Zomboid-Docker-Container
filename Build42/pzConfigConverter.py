#!/usr/bin/env python3
"""
Project Zomboid Configuration to Lua Converter
==============================================

Description:
This script converts a Project Zomboid single-player server configuration file
(.cfg or .ini) into a properly formatted SandboxVars.lua file for dedicated
servers. It preserves all comments, spacing, and groupings so that the resulting
Lua file can be easily read and edited by hand later.

start.sh also runs it inside the container: with --output to write straight into
<SERVER_NAME>_SandboxVars.lua, and with --check to validate a source that is
already Lua before installing it. There is no Lua interpreter in the image, so
--check is the only gate standing between a malformed file and a server that
refuses to load its world.

Usage:
    python pzConfigConverter.py <path_to_config_file> [server_name] [--output PATH]
    python pzConfigConverter.py --check <path_to_lua_file>

Arguments:
    <path_to_config_file>   The path to your single-player .cfg or .ini file.
    [server_name]           (Optional) The name of your server. Defaults to "servertest".
                            The output file will be named <server_name>_SandboxVars.lua.
    --output PATH           (Optional) Write here instead of ./<server_name>_SandboxVars.lua.
    --check PATH            Validate an existing SandboxVars.lua and exit.

Example:
    python pzConfigConverter.py map_sand.cfg MySurvivorServer
"""

import argparse
import os
import re
import sys

# A bare Lua numeral. float() cannot be used as the test: it also accepts "nan",
# "inf" and "1_000", none of which Lua reads as a number -- emitted unquoted they
# become undefined globals (silently nil) or a syntax error.
NUMBER_RE = re.compile(r'^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$')

# Keys that can be written as `key = v`. Anything else needs ["key"] = v, or the
# file will not parse -- e.g. a key with a space or a leading digit.
IDENTIFIER_RE = re.compile(r'^[A-Za-z_]\w*$')

SANDBOXVARS_RE = re.compile(r'^\s*SandboxVars\s*=', re.MULTILINE)
VERSION_RE = re.compile(r'^\s*(?:\["VERSION"\]|VERSION)\s*=', re.MULTILINE)

LUA_ESCAPES = {'\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\t': '\\t'}

INDENT = "    "


class ConversionError(Exception):
    """A problem in the source file that would produce a broken Lua file."""


def quote_lua_string(val):
    """Wraps a value in double quotes, escaping anything that would break out."""
    out = []
    for ch in val:
        escape = LUA_ESCAPES.get(ch)
        if escape is not None:
            out.append(escape)
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append('\\%d' % ord(ch))
        else:
            out.append(ch)
    return '"%s"' % ''.join(out)


def format_lua_value(val):
    """Determines if a value should be a boolean, number, or string in Lua."""
    val = val.strip()

    # Handle empty values
    if not val:
        return '""'

    # Handle booleans
    if val.lower() == 'true':
        return 'true'
    if val.lower() == 'false':
        return 'false'

    # An explicitly quoted value is taken as a string, verbatim. A .cfg carries
    # no type information, so this is the only way to say "this really is text"
    # about a value that looks like a number -- some mods declare options such as
    # a drop rate of ".1" as a string, and typing it as a number would change it.
    if len(val) >= 2 and val.startswith('"') and val.endswith('"'):
        return quote_lua_string(val[1:-1])

    # Handle numbers (integers and floats)
    if NUMBER_RE.match(val):
        return val

    # If it's not empty, boolean, or number, it must be a string. Wrap in quotes.
    return quote_lua_string(val)


def format_lua_key(key):
    """`Zombies` stays bare; `2Bad` or `Some Key` has to be bracketed."""
    if IDENTIFIER_RE.match(key):
        return key
    return '[%s]' % quote_lua_string(key)


def convert_to_lua(filepath):
    """Parses a PZ .cfg file and converts it to a SandboxVars Lua structure while preserving comments."""
    if not os.path.isfile(filepath):
        print("Error: File '%s' not found." % filepath, file=sys.stderr)
        sys.exit(1)

    lua_lines = ["SandboxVars = {"]
    # Path of the table currently open, e.g. ["ZombieLore"]. Supports keys nested
    # deeper than one level: "A.B.C" opens A, then B, and assigns C. Splitting on
    # the first dot only (as this script used to) emitted `B.C = v`, which is a
    # syntax error inside a table constructor, not a nested assignment.
    open_path = []
    # Every table path and every leaf key written so far. A .cfg that comes back
    # to a category it already left would otherwise emit that table twice, and
    # Lua keeps only the last one -- the first block's settings disappear with no
    # error anywhere. Same for a repeated leaf key.
    seen_tables = set()
    seen_keys = set()
    comment_buffer = []

    def indent_for(depth):
        return INDENT * (depth + 1)

    def flush_comments(depth):
        pad = indent_for(depth)
        for c in comment_buffer:
            lua_lines.append("" if c == "" else pad + c)
        comment_buffer.clear()

    def close_to(depth):
        while len(open_path) > depth:
            open_path.pop()
            lua_lines.append(indent_for(len(open_path)) + "},")

    with open(filepath, 'r', encoding='utf-8') as f:
        for lineno, line in enumerate(f, 1):
            stripped = line.strip()

            # Buffer empty lines to preserve spacing
            if not stripped:
                comment_buffer.append("")
                continue

            # Buffer and format comments
            if stripped.startswith('#'):
                # Convert python/ini style comments to lua style
                comment_buffer.append("--" + stripped[1:])
                continue
            elif stripped.startswith('--'):
                comment_buffer.append(stripped)
                continue

            # Anything that is not blank, a comment or a key=value pair used to be
            # dropped without a word, so a typo'd preset converted "successfully"
            # while quietly losing settings.
            if '=' not in stripped:
                print("Warning: line %d is not a comment or key=value pair, skipping: %s"
                      % (lineno, stripped), file=sys.stderr)
                continue

            key, value = stripped.split('=', 1)
            key = key.strip()
            if not key:
                print("Warning: line %d has an empty key, skipping: %s"
                      % (lineno, stripped), file=sys.stderr)
                continue

            formatted_val = format_lua_value(value)

            parts = [p.strip() for p in key.split('.')]
            if any(not p for p in parts):
                raise ConversionError(
                    "line %d: key '%s' has an empty path segment." % (lineno, key))

            table_path, leaf = parts[:-1], parts[-1]

            # Close the tables the new key is not inside of, then open the ones
            # it needs. Comments are flushed after the headers so they stay
            # attached to the key they document.
            common = 0
            while (common < len(open_path) and common < len(table_path)
                   and open_path[common] == table_path[common]):
                common += 1
            close_to(common)
            # Flushed before the table headers, not after: a comment block in a
            # .cfg sits above the group it describes, so emitting it after
            # "ZombieLore = {" would move it inside the table it introduces and
            # push any blank separator to the top of that table.
            flush_comments(len(open_path))

            for name in table_path[common:]:
                open_path.append(name)
                path_key = tuple(open_path)
                if path_key in seen_tables:
                    raise ConversionError(
                        "line %d: category '%s' appears in more than one place in the file. "
                        "Lua would keep only the last block and silently drop the earlier "
                        "one -- move all of its keys together." % (lineno, '.'.join(open_path)))
                seen_tables.add(path_key)
                lua_lines.append(indent_for(len(open_path) - 1) + "%s = {" % format_lua_key(name))

            full_key = tuple(table_path + [leaf])
            if full_key in seen_keys:
                raise ConversionError(
                    "line %d: key '%s' is defined twice; the second value would "
                    "silently win." % (lineno, key))
            seen_keys.add(full_key)

            lua_lines.append(indent_for(len(open_path)) + "%s = %s," % (format_lua_key(leaf), formatted_val))

    # Close any tables still open at the end of the file
    close_to(0)

    # Flush any trailing comments
    flush_comments(0)

    lua_lines.append("}")

    return '\n'.join(lua_lines) + '\n'


def find_lua_problems(text):
    """Cheap structural validation of a SandboxVars.lua. Returns a list of problems.

    Not a Lua parser -- it only skips comments and strings well enough to trust
    the brace count, which is what catches the realistic damage: a truncated
    file, a hand edit that dropped a closing brace, or a file that is not a
    sandbox config at all.
    """
    problems = []

    if not SANDBOXVARS_RE.search(text):
        problems.append("no 'SandboxVars = ...' assignment found; "
                        "this does not look like a sandbox config")
    if not VERSION_RE.search(text):
        problems.append("no VERSION key found; Project Zomboid needs one "
                        "(the stock file starts with VERSION = 6)")

    depth = 0
    i = 0
    n = len(text)
    line = 1
    while i < n:
        ch = text[i]

        if ch == '\n':
            line += 1
            i += 1
            continue

        # Long comment / long string: --[[ ... ]] and [[ ... ]]
        if text.startswith('--', i):
            if text.startswith('--[[', i):
                end = text.find(']]', i + 4)
                if end == -1:
                    problems.append("unterminated long comment starting on line %d" % line)
                    break
                line += text.count('\n', i, end)
                i = end + 2
            else:
                nl = text.find('\n', i)
                i = n if nl == -1 else nl
            continue

        if text.startswith('[[', i):
            end = text.find(']]', i + 2)
            if end == -1:
                problems.append("unterminated long string starting on line %d" % line)
                break
            line += text.count('\n', i, end)
            i = end + 2
            continue

        if ch in ('"', "'"):
            quote = ch
            i += 1
            closed = False
            while i < n:
                c = text[i]
                if c == '\\':
                    i += 2
                    continue
                if c == quote:
                    closed = True
                    i += 1
                    break
                if c == '\n':
                    break
                i += 1
            if not closed:
                problems.append("unterminated string starting on line %d" % line)
                break
            continue

        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth < 0:
                problems.append("unbalanced '}' on line %d (closes a table that was never opened)" % line)
                break
        i += 1

    if depth > 0:
        problems.append("%d unclosed '{' at end of file" % depth)

    return problems


def check_file(filepath):
    """Validates a Lua file in place. Returns True when it is usable."""
    if not os.path.isfile(filepath):
        print("Error: File '%s' not found." % filepath, file=sys.stderr)
        return False

    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()

    problems = find_lua_problems(text)
    if problems:
        print("Error: %s is not a usable SandboxVars.lua:" % os.path.basename(filepath),
              file=sys.stderr)
        for p in problems:
            print("  - %s" % p, file=sys.stderr)
        return False

    return True


def main():
    parser = argparse.ArgumentParser(
        description="Convert a Project Zomboid sandbox .cfg/.ini into SandboxVars.lua.")
    parser.add_argument('config', nargs='?', help="path to the single-player .cfg or .ini file")
    parser.add_argument('server_name', nargs='?', default="servertest",
                        help="server name; output is <server_name>_SandboxVars.lua (default: servertest)")
    parser.add_argument('--output', metavar='PATH',
                        help="write here instead of ./<server_name>_SandboxVars.lua")
    parser.add_argument('--check', metavar='PATH',
                        help="validate an existing SandboxVars.lua and exit")
    args = parser.parse_args()

    if args.check:
        if not check_file(args.check):
            return 1
        print("%s looks like a valid SandboxVars.lua." % os.path.basename(args.check))
        return 0

    if not args.config:
        parser.print_usage(sys.stderr)
        print("Error: a config file is required (or use --check).", file=sys.stderr)
        return 1

    output_filename = args.output or "%s_SandboxVars.lua" % args.server_name

    # With --output the caller is start.sh, writing to a temp file it will move
    # into place itself. Printing "Created /tmp/tmp.XYZ" there is just noise in
    # the container log, and names a path that no longer exists a moment later --
    # so in that mode only warnings and errors (all on stderr) are emitted.
    quiet = bool(args.output)

    if not quiet:
        print("--- Converting %s to Lua ---" % os.path.basename(args.config))

    try:
        lua_content = convert_to_lua(args.config)
    except ConversionError as e:
        print("Error: %s" % e, file=sys.stderr)
        return 1

    # Validate what we just built rather than trusting it. A source file odd
    # enough to produce unbalanced output should fail here, not at world load.
    problems = find_lua_problems(lua_content)
    if problems:
        print("Error: the converted output is not valid; nothing was written:", file=sys.stderr)
        for p in problems:
            print("  - %s" % p, file=sys.stderr)
        return 1

    # newline="\n" so a run on Windows cannot emit CRLF into a file that is read
    # on Linux.
    with open(output_filename, 'w', encoding='utf-8', newline="\n") as out_file:
        out_file.write(lua_content)

    if not quiet:
        print("Success! Created '%s'." % output_filename)
        print("\nHow to use:")
        print("1. Place this generated file into your mounted Zomboid Server data folder:")
        print("   (e.g. ./zomboid_data/Server/%s)" % os.path.basename(output_filename))
        print("2. Restart your Docker container.")
        print("\nOr let the container do it: point PZ_SANDBOX_SOURCE at your .cfg")
        print("and start.sh converts and installs it on every boot. See the README.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
