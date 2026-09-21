#pragma once

#if !defined( RIPWIRE_INGEST_TU )
#error "ingest_nix.h is a section of ingest.cpp; include it only there"
#endif

namespace rw
{
namespace
{

// Included by ingest.cpp after the shared AST helpers, before ingest_sidecap.h.
// Nix's definition node is a `binding` (`name = expression ;`) — the SAME node inside { }, rec { },
// let { } and let … in. The binding carries no `body:` field, so defBodyNodeOf finds nothing and the
// definition's span would stop at the attrpath; these two hooks give a Nix function a real
// signature/body split and a call-comparable arity (the same slots elixirBody/elixirParams fill).

/// Return a binding's VALUE — the `expression:` field, which is the whole body the lambda evaluates.
/// The node kind is checked by the caller; a null expression returns a null node.
TSNode nixBody( TSNode defNode ) noexcept
{
    return fieldChild( defNode, NodeField::Expression );
}

/// Count a Nix lambda's parameters, saturating at UINT16_MAX. A lambda takes EITHER a bare
/// `universal` identifier (`name = x: …`, one parameter) OR a `formals` pattern
/// (`name = { a, b ? c, ... }: …`, N formals — `...` is not a formal). Curried lambdas
/// (`f = a: b: …`) nest a further function_expression under `body:`; the count answers for
/// the FIRST application only, which is the arity the call `f x` binds against. Zero when the
/// binding's value is not a lambda — `d.params` stays 0 for every other shape.
std::uint16_t nixParams( TSNode defNode ) noexcept
{
    const TSNode fn = nixBody( defNode );
    if( ts_node_is_null( fn ) || std::strcmp( ts_node_type( fn ), "function_expression" ) != 0 )
    {
        return 0;
    }
    const TSNode formals = fieldChild( fn, NodeField::Formals );
    if( !ts_node_is_null( formals ) )
    {
        std::uint32_t count = 0;
        for( std::uint32_t i = 0; i < ts_node_named_child_count( formals ); ++i )
        {
            count += std::strcmp( ts_node_type( ts_node_named_child( formals, i ) ), "formal" ) == 0 ? 1u : 0u;
        }
        return std::uint16_t( std::min( count, std::uint32_t( 65535 ) ) );
    }
    return ts_node_is_null( fieldChild( fn, NodeField::Universal ) ) ? std::uint16_t( 0 ) : std::uint16_t( 1 );
}

/// Return whether a binding's VALUE is a lambda — the one definition shape that is callable, so
/// captureTagsFacts reclassifies the tags.scm t="var" capture to t="function" for it.
bool nixBodyIsFunction( TSNode defNode ) noexcept
{
    const TSNode fn = nixBody( defNode );
    return !ts_node_is_null( fn ) && std::strcmp( ts_node_type( fn ), "function_expression" ) == 0;
}

/// Decide whether a candidate definition or call capture is kept. Definitions: a binding captures
/// only at MODULE scope — any DATA binding whose parent chain crosses a lambda body is declined (the
/// function-scope rule Python applies to local variables; a call inside such a binding attributes to
/// the enclosing function, which is the honest caller), while a FUNCTION-valued binding stays a
/// callable at any depth (the Lua `M.f` precedent — a nested named function is a callable wherever it
/// is written). References: a bare `import` head is declined — `import ./x.nix` is a file dependency,
/// not a call to a symbol named "import", and nixPrepare below owns it.
bool nixKeepCapture( TSNode role, TSNode name, bool isDef, SymKind kind, std::string_view src ) noexcept
{
    (void)name;
    if( !isDef )
    {
        if( std::strcmp( ts_node_type( role ), "apply_expression" ) == 0 )
        {
            const TSNode head = fieldChild( role, NodeField::Function );
            if( !ts_node_is_null( head ) && std::strcmp( ts_node_type( head ), "variable_expression" ) == 0 && nodeTextOf( fieldChild( head, NodeField::Name ), src ) == "import" )
            {
                return false; // `import ./x.nix` is a file dependency, not a call — nixPrepare owns it
            }
        }
        return true;
    }
    if( kind == SymKind::Var )
    {
        // Module scope = the ancestor chain crosses AT MOST ONE lambda, and that lambda is the
        // outermost one (the file's own root lambda — `{ ... }: { ... }` is the dominant module shape
        // and its returned attrset IS the module). Two lambdas mean the binding lives inside a
        // mid-function lambda's returned structure: a local, not a module symbol. Zero lambdas means
        // the file's root is data and the file itself is the module unit.
        TSNode firstFn = {};
        TSNode lastFn = {};
        for( TSNode p = ts_node_parent( role ); !ts_node_is_null( p ); p = ts_node_parent( p ) )
        {
            if( std::strcmp( ts_node_type( p ), "function_expression" ) == 0 )
            {
                if( ts_node_is_null( firstFn ) ) { firstFn = p; }
                lastFn = p;
            }
        }
        return ts_node_is_null( firstFn ) || ts_node_eq( firstFn, lastFn );
    }
    return true;
}

// ── file dependencies (round two) ───────────────────────────────────────────────────────────────────
// Nix has no import statement with a module name; a file dependency is a PATH LITERAL in the source:
//   import ./x.nix            — an apply whose head is the bare `import` and whose argument is a path
//   imports = [ ./a ./b.nix ] — the module-system list: a binding named `imports` holding path literals
// Both resolve RELATIVE TO THE IMPORTING FILE (resolve.h's joinNormalizeLookup, the C quote-include
// rule; test/nixcheck.sh). The floors stay the ones queries/nix/tags.scm states: `<nixpkgs>` spaths
// are NIX_PATH lookups outside the repo (captured as angle includes, resolved to nothing — the same
// disclosure an unresolvable `#include <vector>` gets), `~/...` hpaths are home-rooted, and a computed
// path (`./. + "/x"`, `"${./x}/y"`) either carries no path node or carries one whose text names no
// file — captured, unresolved, disclosed, never guessed.

/// Return node when it is a path-literal node, or a null node for anything else. A plain identifier is
/// a VARIABLE (an indirection this tool cannot see through); a string is a computed path. Both floor.
TSNode nixPathNode( TSNode n ) noexcept
{
    if( ts_node_is_null( n ) ) { return {}; }
    const char* t = ts_node_type( n );
    if( std::strcmp( t, "path_expression" ) == 0 || std::strcmp( t, "hpath_expression" ) == 0 || std::strcmp( t, "spath_expression" ) == 0 )
    {
        return n;
    }
    return {};
}

/// One file-dependency site: the Include record plus its import-role use-site ref, both sited on the
/// PATH node (the thing that names the file — for a list element that is the element, not the binding).
void nixEmitDependency( TSNode path, std::uint32_t fileId, std::string_view src, std::vector<Include>& includes,
                        std::vector<RawRef>& refs )
{
    std::string target( nodeTextOf( path, src ) );
    RawRef r;
    r.fileId = fileId;
    r.startByte = ts_node_start_byte( path );
    r.line = ts_node_start_point( path ).row + 1;
    r.role = RefRole::Import;
    r.lang = Lang::Nix;
    r.name = importName( target );
    if( !r.name.empty() ) { refs.push_back( std::move( r ) ); }
    Include inc;
    inc.fileId = fileId;
    inc.isAngle = std::strcmp( ts_node_type( path ), "spath_expression" ) == 0; // <nixpkgs>: the angle tier
    inc.byte = ts_node_start_byte( path );
    inc.target = std::move( target );
    includes.push_back( std::move( inc ) );
}

/// Walk a Nix tree and emit every file-dependency site. A bounded explicit-stack pre-order over ALL
/// named nodes — imports live anywhere a binding or an apply does (the module shape puts `imports = [
/// … ]` inside the root lambda's returned attrset), so unlike the allowlisted container walks there is
/// no descent table to maintain. Exceeding the shared depth bound DEGRADES — deeper sites are simply
/// not captured, the file still indexes — exactly like captureIncludes' bound.
void nixPrepare( TSNode root, std::uint32_t fileId, std::string_view src, std::vector<Include>& includes,
                 std::vector<RawRef>& refs, ExtractShortfall& shortfall )
{
    struct NixFrame
    {
        TSNode node;
        std::uint16_t depth;
    };
    std::vector<NixFrame> stack;
    stack.reserve( 64 );
    stack.push_back( { root, 0 } );
    ChildCursor cursor( root );
    std::vector<TSNode> kids;
    kids.reserve( 64 );
    while( !stack.empty() )
    {
        const NixFrame frame = stack.back();
        stack.pop_back();
        if( frame.depth > 256 )
        {
            DISCLOSE( shortfall, ExtractShortfall::DisclosureWhy::ImportNestingTooDeep,
                      "ingest: nix tree nesting past the depth bound — deeper imports not captured" );
            continue;
        }
        const TSNode n = frame.node;
        const char* t = ts_node_type( n );
        if( std::strcmp( t, "apply_expression" ) == 0 )
        {
            // `import ./x.nix` — the head must be the BARE `import` variable; `lib.import ./x` is a
            // call to some function named import, not the keyword
            const TSNode head = fieldChild( n, NodeField::Function );
            if( !ts_node_is_null( head ) && std::strcmp( ts_node_type( head ), "variable_expression" ) == 0 && nodeTextOf( fieldChild( head, NodeField::Name ), src ) == "import" )
            {
                const TSNode arg = fieldChild( n, NodeField::Argument );
                if( const TSNode path = nixPathNode( arg ); !ts_node_is_null( path ) )
                {
                    nixEmitDependency( path, fileId, src, includes, refs );
                }
            }
        }
        else if( std::strcmp( t, "binding" ) == 0 )
        {
            // `imports = [ ./a ./b.nix ]` — the module-system's one list spelling. Only the exact name
            // `imports` (the LAST attr: `host.imports` is some other thing's data), and only a LIST
            // value: a bare `imports = ./x` is that attrset's own data binding, not the module system.
            // NOTE: no early-out here — every branch must fall through to the descend below, because
            // the import applies this walker exists for sit INSIDE binding values.
            const TSNode ap = fieldChild( n, NodeField::Attrpath );
            const TSNode last = ts_node_is_null( ap ) ? TSNode {} : ts_node_named_child( ap, ts_node_named_child_count( ap ) - 1 );
            if( !ts_node_is_null( last ) && std::strcmp( ts_node_type( last ), "identifier" ) == 0 && nodeTextOf( last, src ) == "imports" )
            {
                const TSNode value = fieldChild( n, NodeField::Expression );
                if( !ts_node_is_null( value ) && std::strcmp( ts_node_type( value ), "list_expression" ) == 0 )
                {
                    for( std::uint32_t i = 0; i < ts_node_named_child_count( value ); ++i )
                    {
                        if( const TSNode path = nixPathNode( ts_node_named_child( value, i ) ); !ts_node_is_null( path ) )
                        {
                            nixEmitDependency( path, fileId, src, includes, refs );
                        }
                    }
                }
            }
        }
        collectChildren( n, cursor.cur, kids );
        for( std::size_t i = kids.size(); i > 0; --i )
        {
            stack.push_back( { kids[i - 1], static_cast<std::uint16_t>( frame.depth + 1 ) } );
        }
    }
}

} // namespace
} // namespace rw
