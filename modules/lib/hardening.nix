# The sandbox keys every unit here shares; units add or override per-service
# deltas with `hardening // { ... }`.
{
  NoNewPrivileges = true;
  PrivateTmp = true;
  ProtectHome = true;
  ProtectSystem = "strict";
}
