# the module shape: an anonymous root lambda returning the module's attrset
{ lib, config, ... }:
{
  # multi-segment attrpath — the LAST attr is the name, and it must be the ONLY capture here
  options.host.caddy.enable = lib.mkEnableOption "caddy";

  # lambda-valued bindings are functions; a curried chain counts its FIRST application
  mkTitle = prefix: text: "${prefix} — ${text}";
  curried = a: b: a + b;

  # formals: two counted formals; the default value and the ellipses are not formals
  formalFn = { name, arch ? "x86_64", ... }: "${name}-${arch}";

  # the one decision spelling Nix has: an if expression, worth +1 in cx
  branchy = c: if c then 1 else 0;

  # a data binding nested inside a mid-function lambda is a LOCAL, not a module symbol
  midLambda = x: { inner = mkTitle x "y"; };

  # a call inside a top-level data binding attributes to that binding (the honest caller)
  usesMkTitle = mkTitle "t" "u";

  # dynamic dispatch: the head binds at runtime, no edge is minted
  callPkg = callPackage ./missing.nix { };

  # import is a file dependency, not a call — no edge in round one
  module = import ./plain.nix;

  # a MISSING relative target: captured, unresolved, no edge — disclosed, never guessed
  ghost = import ./nope.nix;

  # the NIX_PATH floor: an <nixpkgs> spath is an angle include resolved against the evaluator's
  # environment, never this tree
  pkgs = import <nixpkgs> { };
}
