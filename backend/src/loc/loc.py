#!/usr/bin/env python3

import argparse
import sys
import os

import lil
import my_util

__version__ = '0.0.0'
__prog__ = 'loc'

def parser():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--version',
        help='Display version',
        action='version',
        version='%(prog)s {}'.format(__version__)
    )
    parser.add_argument(
        'f',
        help="LOC source file"
    )
    parser.add_argument(
        '-m', '--print-manifolds',
        help="help",
        action='store_true',
        default=False
    )
    args = parser.parse_args()
    return(args)

if __name__ == '__main__':
    args = parser()

    raw_lil = lil.compile_loc(args.f)
    exports = lil.get_exports(raw_lil)
    source = lil.get_src(raw_lil)
    manifolds = lil.get_manifolds(raw_lil)
    languages = set([l.lang for m,l in manifolds.items()])

    loc_home = os.path.expanduser("~/.loc")
    loc_tmp = "%s/tmp" % loc_home

    try:
        os.mkdir(loc_tmp)
    except FileExistsError:
        pass

    for i in range(100):
        try:
            outdir="{}/loc_{}".format(loc_tmp, i)
            os.mkdir(outdir)
            break
        except FileExistsError:
            pass
    else:
        err("Too many temporary directories")

    if(args.print_manifolds):
        for k,m in manifolds.items():
            m.print()

    #  for language in languages:
    #      build_manifold_pool(
    #          language  = language,
    #          exports   = exports,
    #          manifolds = manifolds,
    #          outdir    = outdir
    #          home      = loc_home
    #      )
