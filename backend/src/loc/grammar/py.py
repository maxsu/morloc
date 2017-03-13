from grammar.base_grammar import Grammar

class PyGrammar(Grammar):
    def __init__(
        self,
        source,
        manifolds,
        outdir,
        home
    ):
        self.source    = source
        self.manifolds = manifolds
        self.outdir    = outdir
        self.home      = home
        self.TRUE      = "True"
        self.FALSE     = "False"
        self.lang      = "py"
        self.INDENT    = 4
        self.SEP       = ', '
        self.BIND      = '='
        self.AND       = ' and '
        self.LIST      = '[{values}]'
        self.POOL      = '''\
#!/usr/bin/env python3

import sys
import os
import subprocess

outdir = "{outdir}"

{type_map}

{source}

{manifolds}

{nat2uni}

{uni2nat}

if __name__ == '__main__':
    args = sys.argv
    cmd_str = "{{function}}({{args}})"
    arg_str = ', '.join(args[2:])
    cmd = cmd_str.format(function="show_" + args[1], args=arg_str)
    try:
        print(eval(cmd))
    except SyntaxError as e:
        print("Syntax error in:\\n%s\\n%s" % (cmd, e), file=sys.stderr)
'''
        self.TYPE_MAP         = '''# skipping type map'''
        self.TYPE_MAP_PAIR    = "    '{key}' : '{type}'"
        self.TYPE_ACCESS      = '''output_type[{key}]'''
#        self.CAST_NAT2UNI     = '''natural_to_universal({key}, {type})'''
#        self.CAST_UNI2NAT     = '''universal_to_natural({key}, {type})'''
        self.CAST_NAT2UNI     = '''{key}'''
        self.CAST_UNI2NAT     = '''{key}'''
        self.NATIVE_MANIFOLD = '''\
def {mid}({marg_uid}):
# {comment}
{blk}
'''
        self.NATIVE_MANIFOLD_BLK = '''\
{hook0}
{cache}
{hook1}
return b\
'''
        self.SIMPLE_MANIFOLD = '''\
def {mid}({marg_uid}):
# {comment}
{blk}
'''
        self.SIMPLE_MANIFOLD_BLK = '''\
return {function}({arguments})\
'''
        self.UID_WRAPPER = '''\
{mid}_uid = 0
def wrap_{mid}(*args, **kwargs):
{blk}
'''
        self.UID_WRAPPER_BLK = '''\
global {mid}_uid
{mid}_uid += 1
return {mid} (*args, **kwargs, uid={mid}_uid )\
'''
        self.UID = 'uid'
        self.MARG_UID = '{marg}, {uid}'
        self.WRAPPER_NAME = 'wrap_{mid}'
        self.FOREIGN_MANIFOLD = '''\
def {mid}({marg_uid}):
# {comment}
{blk}
'''
        self.FOREIGN_MANIFOLD_BLK = '''\
foreign_pool = os.path.join(outdir, "call.{foreign_lang}")
out,result = None, None
try:
    cmd = [foreign_pool] + [{args}]
    cmd = [str(s) for s in cmd]
    cmd_str = " ".join(cmd)
    result = subprocess.run(
        cmd,
        stderr=subprocess.PIPE,
        stdout=subprocess.PIPE,
        encoding='utf-8',
        check=True
    )
except subprocess.CalledProcessError as e:
    msg = "ERROR: non-zero exist status from call.py::{mid}, cmd='%s'"
    print(msg % cmd_str, file=sys.stderr)
    print("   %s" % e, file=sys.stderr)
except Exception as e:
    msg = "ERROR: unknown error in call.py::{mid}, cmd='%s'"
    print(msg % cmd_str, file=sys.stderr)
    print("   %s" % e, file=sys.stderr)
try:
    out = read_{mid}(result.stdout)
except Exception as e:
    msg = "ERROR: read_{mid} failed in call.py::{mid}, cmd='%s'"
    print(msg % cmd_str, file=sys.stderr)
    print("   %s" % e, file=sys.stderr)
if result:
    print(result.stderr, file=sys.stderr, end="")
return out 
'''
        self.CACHE = '''\
if {cache}_chk("{mid}"{uid}{cache_args}):
{if_blk}
else:
{else_blk}
'''
        self.CACHE_IF = '''\
{hook8}
b = {cache}_get("{mid}"{uid}{cache_args})
{hook9}\
'''
        self.CACHE_ELSE = '''\
{hook2}
{validate}
{hook3}\
'''
        self.DATCACHE_ARGS = '''outdir="{outdir}"'''
        self.DO_VALIDATE = '''\
if {checks}:
{if_blk}
else:
{else_blk}
'''
        self.RUN_BLK = '''\
{hook4}
b = {function}({arguments})
{cache_put}
{hook5}
'''
        self.RUN_BLK_VOID = '''\
{hook4}
{function}({arguments})
b = None
{cache_put}
{hook5}
'''
        self.FAIL_BLK = '''\
{hook6}
b = {fail}
{cache_put}
{hook7}\
'''
        self.FAIL_BLK_VOID = '''\
{hook6}
{fail}
b = None
{cache_put}
{hook7}\
'''
        self.FAIL = '{fail}({marg_uid})'
        self.DEFAULT_FAIL = 'None'
        self.NO_VALIDATE = '''\
{hook4}
b = {function}({arguments})
{cache_put}
{hook5}
'''
        self.CACHE_PUT = '''\
{cache}_put("{mid}", b{other_args})
'''
        self.MARG          = 'x{i}'
        self.ARGUMENTS     = '{inputs}{sep}{fargs}'
        self.MANIFOLD_CALL = '{hmid}({marg_uid})'
        self.CHECK_CALL    = '{hmid}({marg_uid})'
        self.HOOK          = '{hmid}({marg_uid})'
