rec {
  minimal = {
    path = ./minimal;
    description = "Minimal Executable";
  };
  dependency = {
    path = ./dependency;
    description = "With Dependency";
  };
  incremental = {
    path = ./incremental;
    description = "With Incremental builds";
  };
  local = {
    path = ./local;
    description = "With Local packages";
  };
  default = minimal;
}
