import re

import manifold
from util import err,indent

nexus_template = '''\
#!/usr/bin/env python3

import argparse
import subprocess
import sys
import os
import shutil

outdir = "{outdir}"

def parser():
    parser = argparse.ArgumentParser(
        description="A program generated from a LOC script", 
        usage='manifold-nexus <mid>',
        prog="manifold-nexus"
    )
    parser.add_argument(
        '--version',
        help='Display version',
        action='version',
        version='{prog} {version}'
    )
    parser.add_argument(
        '-d', '--delete',
        help="Remove this manifold nexus and temporary directory",
        action='store_true',
        default=False
    )
    sub = parser.add_subparsers(
        help='.',
        metavar='[ for more help: manifold-nexus <subcommand> -h ]',
        title='manifolds'
    )

{manifold_parsers}

    args = parser.parse_args()

    return(args)

{manifold_calls}

def show(x, vtype):
    x = x.strip()
    literal = {{"Int", "String"}}
    if(len(x) == 0):
        pass
    elif(vtype in literal):
        print(x)
    elif(vtype == "NULL"):
        pass
    else:
        if os.path.exists(x):
            subprocess.run(
                ["cat", x],
                stderr=subprocess.PIPE,
                encoding='utf-8'
            )
        else:
            print(x)

if __name__ == '__main__':
    args = parser()
    if args.delete:
        shutil.rmtree(outdir)
        os.remove("manifold-nexus.py")
    else:
        result, vtype = args.func()
        returncode=result.returncode
        show(result.stdout, vtype=vtype)
        print(result.stderr, file=sys.stderr, end="")
        sys.exit(returncode)
'''

parser_template = '''\

{mid}_parser = sub.add_parser(
    '{alias}',
    usage="manifold-nexus {alias}",
    description="{doc}",
    help="({lang}) {doc}"
)
{mid}_parser.set_defaults(func={mid})
'''

call_template = '''\
def {mid}():
    path = os.path.join(outdir, "call.{lang}")
    result = subprocess.run(
        [path, "{mid}"],
        stderr=subprocess.PIPE,
        stdout=subprocess.PIPE,
        encoding='utf-8'
    )
    return (result, "{vtype}")
'''

def build_manifold_nexus(
    languages,
    exports,
    manifolds,
    outdir,
    home,
    version,
    prog
):
    mparsers = []
    mcalls = []

    for k,v in manifolds.items():

        try:
            alias = exports[k]
        except KeyError:
            continue

        if v.mdoc:
            doc = v.mdoc[1:-1]
        else:
            doc = ""

        parser_string = indent(
            parser_template.format(
                mid  = k,
                alias=alias,
                func = v.func,
                lang = v.lang,
                doc  = doc
            ),
            n=4
        )

        call_string = call_template.format(
            mid=k,
            lang=v.lang,
            vtype=v.type
        )
        mcalls.append(call_string)
        mparsers.append(parser_string)

    return nexus_template.format(
        prog=prog,
        version=version,
        outdir=outdir,
        manifold_parsers='\n'.join(mparsers),
        manifold_calls='\n'.join(mcalls)
    )