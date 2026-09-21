; ripwire Nix tags — written for ripwire (.nix). Derived from nix-community/tree-sitter-nix
; 17f290c8b5104d9aba8a1ba7383a2ca83c3d14c4's node-types.json and verified against real parses
; (test/nixfix, plus the STEP 0 corpus: 43,338 nixpkgs .nix files parse clean under this grammar).
;
; A Nix FILE is one expression. There is no `class` and no `import` directive at the grammar level;
; the structural unit is the `binding` (`name = expression ;`) — the SAME `binding` node inside
; `{ }`, `rec { }`, `let { }` and `let … in`, so one capture pattern covers all four spellings.
; One pattern serves BOTH kinds: ingest_nix.h's nixBodyIsFunction reclassifies a binding whose
; value is a lambda to t="function" (the callable population), and everything else stays t="var"
; (data) — the same module-scope rule Python applies to `NAME = value`.
;
; The LAST attr of an attrpath is the name a call binds to (`host.caddy.enable` names `enable`), so
; each pattern below anchors on it: the single-segment pattern pins first+last (exactly one attr),
; the multi-segment pattern requires a preceding identifier and pins last. That is what byName
; resolves on, and it cannot double-capture a middle segment.
;
; Deliberately NOT captured: a DATA binding nested inside a lambda's returned attrset (the
; function-scope rule Python applies to local variables — nixKeepCapture declines it; a call inside
; such a binding attributes to the enclosing FUNCTION, which is the honest caller). Also not captured:
; `inherit` aliases (an alias binds a name whose definition lives elsewhere; a future round may map
; inherit_from to the import lane).
;
; Deliberately NOT captured (CANNOT be, and it is disclosed rather than faked) — the honest floor:
;   - DYNAMIC dispatch: a call whose head is itself a binding value or an apply result
;     (`callPackage ./x { }`, `f = g; f 1`, `(f a) b`) binds at runtime; the head capture declines
;     and no edge is minted. `--callers` on such a callee reads "none found", never "none exists" —
;     the house rule, stated out loud. callPackage is the standard idiom and this is the largest
;     single blind spot of the Nix lane.
;   - Value-dependent imports: `import (./. + "/x")` and `import "${./x}/file.nix"` carry no
;     path-literal argument. ingest.cpp::captureIncludes reads literal paths only, and a computed
;     path produces no edge. This degrades honestly rather than guessing.
;   - `<nixpkgs>` spath: a NIX_PATH lookup resolved OUTSIDE the repository — never an in-repo edge,
;     never a definition this tree owns.
;   - Dynamic attrpath segments (`${...}.x = ...`): the name capture requires the LAST attr to be a
;     plain identifier, so a binding whose name ends in an interpolation mints nothing.

; ---- definitions ----
; one shape covers { }, rec { }, let { } and let … in: every binding is a `binding` node.
; value = lambda → reclassified t="function" by ingest_nix.h's nixBodyIsFunction (a nested named
; function stays a callable at any depth — the Lua `M.f` precedent); value = anything else → t="var".

; single-segment attrpath: `name = ...`
(binding
  attrpath: (attrpath
    . attr: (identifier) @name
    .)) @definition.constant

; multi-segment attrpath: `host.caddy.enable = ...` — the LAST attr is the name. The attrpath's
; separator `.` tokens are UNNAMED children, so adjacency anchors alone cannot skip them: the
; preceding attr and the literal "." token are part of the pattern.
(binding
  attrpath: (attrpath
    attr: (identifier)
    "."
    attr: (identifier) @name
    .)) @definition.constant

; ---- references (calls) ----

; f x  /  f { ... }  — bare-name call head
(apply_expression
  function: (variable_expression
    name: (identifier) @name)) @reference.call

; lib.f x — single-attribute select head (the dominant nixpkgs spelling); both anchors pin the
; one-element attrpath, so nothing else in it can double-capture
(apply_expression
  function: (select_expression
    attrpath: (attrpath
      . attr: (identifier) @name
      .))) @reference.call

; a.b.f x — multi-attribute select head: the LAST attr is what the call binds to (same unnamed
; "." separators as the definition pattern above)
(apply_expression
  function: (select_expression
    attrpath: (attrpath
      attr: (identifier)
      "."
      attr: (identifier) @name
      .))) @reference.call
