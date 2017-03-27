#include "build.h"

void build_manifolds(Ws* ws_top, bool verbose_infer){

    resolve_grprefs(ws_top);

    resolve_derefs(ws_top);

    resolve_refers(ws_top);

    link_modifiers(ws_top);

    propagate_nargs(ws_top);

    set_as_function(ws_top);

    link_inputs(ws_top);

    infer_types(ws_top, verbose_infer);
}
