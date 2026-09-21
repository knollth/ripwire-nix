# the data shape: the file's root IS the attrset, the file itself is the module unit
{
  answer = 1;

  # a cross-file call: invokes (this file) -> mkTitle (mod.nix) by bare name
  invokes = mkTitle "z" "w";

  # a nested function inside the root data file is still a callable
  localFn = y: lib.y;

  # a multi-segment lambda-valued binding: the last attr is the function's name
  options.services.caddy.readPort = p: p;
}
