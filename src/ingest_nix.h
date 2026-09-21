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
/// not a call to a symbol named "import", and ingest.cpp::captureIncludes owns it (round two).
bool nixKeepCapture( TSNode role, TSNode name, bool isDef, SymKind kind, std::string_view src ) noexcept
{
    (void)name;
    if( !isDef )
    {
        if( std::strcmp( ts_node_type( role ), "apply_expression" ) == 0 )
        {
            const TSNode head = fieldChild( role, NodeField::Function );
            if( !ts_node_is_null( head ) && std::strcmp( ts_node_type( head ), "variable_expression" ) == 0
                && nodeTextOf( fieldChild( head, NodeField::Name ), src ) == "import" )
            {
                return false;   // `import ./x.nix` is a file dependency, not a call — round two owns it
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
        TSNode lastFn  = {};
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

} // namespace
} // namespace rw
