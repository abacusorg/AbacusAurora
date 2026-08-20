#!/usr/bin/env python3
"""Generate one <SimName>.par2 per simulation from a list file and a template.

Reads a whitespace-separated list, one simulation per line, whose column layout
is declared by a '# columns:' comment ahead of the first data line:

    # columns: SSS BBB CCC PPP MMM
    AbacusAurora_small_cCCC_phPPP_mMMM   Small   000 300 000

The header may name any of the recognized tokens (see TOKENS below) in any
order, but must name SSS.  SSS is itself a template: the other tokens are
substituted into it to give the SimName, which is also the output filename
(<SimName>.par2).  Then every token, SSS included, is substituted into
template.par2 to produce the file.

The header and the template must declare exactly the same tokens, and an SSS
pattern may only use tokens the header declares; any mismatch is fatal before
anything is written.  A different column layout therefore needs its own list
file and template, rather than quietly leaving a token unsubstituted.

Substitution is plain, case-sensitive text replacement -- no regex, no word
boundaries -- done in ONE pass, so a value that happens to contain a token
(e.g. a SimName containing 'CCC') is never rescanned and re-substituted.

Blank lines are skipped and a '#' anywhere starts a comment, so section notes
and trailing remarks can be used freely in the body of the list.

An existing output file is not overwritten unless -f is given; it is reported
and skipped, so re-running after adding rows to the list only creates what is
missing.

Usage:
    ./make_par2.py                    # <thisdir>.dat, its template.par2, write
    ./make_par2.py -n                 # dry run: say what would be written
    ./make_par2.py -f                 # overwrite existing .par2 files
    ./make_par2.py -fn                # dry run, showing what -f would replace
    ./make_par2.py mylist -t alt.par2
"""

import argparse
import re
import sys
from pathlib import Path

# Every substitution token a '# columns:' line may name.  Add a new variation
# axis here; a header naming anything else is rejected rather than guessed at.
TOKENS = ['SSS', 'BBB', 'CCC', 'PPP', 'MMM']

# SSS is both the SimName and the output filename, so it is always needed.
REQUIRED_TOKENS = ['SSS']

# The layout declaration, matched against the comment part of a line: the '#'
# has already been stripped by the time we get here.
HEADER_RE = re.compile(r'^\s*columns\s*:\s*(.*)$')


def die(msg):
    """Report a whole-file problem and stop, having written nothing."""
    sys.exit(f'{sys.argv[0]}: {msg}')


def substitute(text, values):
    """Replace every token in `values` simultaneously, case-sensitively.

    One pass via a single alternation, rather than a chain of str.replace calls:
    sequential replacement would rescan text we just inserted, so a value
    containing another token would get mangled.  Tokens are matched literally
    and longest first, so one token being a substring of another is settled by
    length rather than by the order the header happened to list them in.
    """
    if not values:
        return text
    keys = sorted(values, key=len, reverse=True)
    pattern = re.compile('|'.join(re.escape(k) for k in keys))
    return pattern.sub(lambda m: values[m.group(0)], text)


def parse_header(spec, where):
    """Validate one '# columns:' declaration and return the columns it names."""
    columns = spec.split()
    if not columns:
        die(f'{where}: "# columns:" names no columns')
    unknown = [c for c in columns if c not in TOKENS]
    if unknown:
        die(f'{where}: unknown column name(s) {" ".join(unknown)}; '
            f'known tokens are {" ".join(TOKENS)}')
    repeated = [c for c in dict.fromkeys(columns) if columns.count(c) > 1]
    if repeated:
        die(f'{where}: repeated column name(s) {" ".join(repeated)}')
    missing = [c for c in REQUIRED_TOKENS if c not in columns]
    if missing:
        die(f'{where}: column list must name {" ".join(missing)}')
    return columns


def read_list(listfn):
    """Return (columns, [(lineno, fields), ...]) for the data lines of the list.

    The layout comes from the '# columns:' comment, which must precede the first
    data line, so the column order is whatever the file says rather than a
    convention baked into this script.  Blank lines and comments are skipped; a
    '#' anywhere starts a comment, so a trailing note on a data line is fine.
    Rows with the wrong number of columns come back too -- the caller reports
    them, so one malformed line doesn't hide the rest.
    """
    columns = header_lineno = None
    rows = []
    for lineno, raw in enumerate(listfn.read_text().splitlines(), start=1):
        data, _, comment = raw.partition('#')
        data = data.strip()
        header = HEADER_RE.match(comment) if not data else None
        if header:
            if columns is not None:
                die(f'{listfn}:{lineno}: a second "# columns:" line; '
                    f'the first is line {header_lineno}')
            columns = parse_header(header.group(1), f'{listfn}:{lineno}')
            header_lineno = lineno
        elif data:
            if columns is None:
                die(f'{listfn}:{lineno}: data before any "# columns:" line; '
                    f'add e.g.\n    # columns: {" ".join(TOKENS)}')
            rows.append((lineno, data.split()))
    if columns is None:
        die(f'{listfn}: no "# columns:" line; add e.g.\n'
            f'    # columns: {" ".join(TOKENS)}')
    return columns, rows


def check_template(columns, template, listfn, templatefn):
    """Require the list and the template to agree on the set of tokens.

    Either mismatch would otherwise pass unnoticed: a token the template uses
    but the list never supplies survives into the output verbatim, and a column
    the template never mentions is a column of the list doing nothing.
    """
    unsupplied = [t for t in TOKENS if t not in columns and t in template]
    if unsupplied:
        die(f'{templatefn} uses {" ".join(unsupplied)}, which {listfn} '
            f'does not declare in its "# columns:" line')
    unused = [c for c in columns if c not in template]
    if unused:
        die(f'{listfn} declares {" ".join(unused)}, which {templatefn} '
            f'never uses')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('list', nargs='?', default=f'{Path.cwd().name}.dat',
                    help='list file, one simulation per line '
                         '(default: <thisdir>.dat, i.e. %(default)s)')
    ap.add_argument('-t', '--template',
                    help='template to substitute into '
                         '(default: template.par2 beside the list file)')
    ap.add_argument('-n', '--dry-run', action='store_true',
                    help='report what would be written, without writing')
    ap.add_argument('-f', '--force', action='store_true',
                    help='overwrite existing .par2 files instead of skipping them')
    args = ap.parse_args()

    listfn = Path(args.list)
    outdir = listfn.parent
    templatefn = Path(args.template) if args.template else outdir / 'template.par2'
    for fn in (listfn, templatefn):
        if not fn.is_file():
            die(f'no such file: {fn}')
    template = templatefn.read_text()

    columns, rows = read_list(listfn)
    check_template(columns, template, listfn, templatefn)

    written = skipped = replaced = 0
    errors = []
    seen = {}   # SimName -> lineno that first produced it

    for lineno, fields in rows:
        if len(fields) != len(columns):
            errors.append(f'line {lineno}: expected {len(columns)} columns '
                          f'({" ".join(columns)}), got {len(fields)}: {" ".join(fields)}')
            continue
        values = dict(zip(columns, fields))

        undeclared = [t for t in TOKENS if t not in columns and t in values['SSS']]
        if undeclared:
            die(f'{listfn}:{lineno}: SimName template {values["SSS"]} uses '
                f'{" ".join(undeclared)}, which is not declared in the '
                f'"# columns:" line')

        # SSS is itself a template; resolve it before it becomes a substitution value.
        simname = substitute(values['SSS'],
                             {k: v for k, v in values.items() if k != 'SSS'})
        values['SSS'] = simname

        if simname in seen:
            errors.append(f'line {lineno}: {simname} was already generated by '
                          f'line {seen[simname]}; skipping the duplicate')
            continue
        seen[simname] = lineno

        outfn = outdir / f'{simname}.par2'
        overwriting = outfn.exists()
        if overwriting and not args.force:
            print(f'exists, skipping:  {outfn}')
            skipped += 1
            continue

        if args.dry_run:
            print(f'would {"replace" if overwriting else "write":8s}   {outfn}')
        else:
            outfn.write_text(substitute(template, values))
            print(f'{"replaced" if overwriting else "wrote":9s}          {outfn}')
        written += 1
        replaced += overwriting

    verb = 'would write' if args.dry_run else 'wrote'
    detail = f' ({replaced} overwritten)' if replaced else ''
    print(f'\n{verb} {written}{detail}, skipped {skipped} existing, {len(errors)} problem(s)')
    for e in errors:
        print(f'  {e}', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
