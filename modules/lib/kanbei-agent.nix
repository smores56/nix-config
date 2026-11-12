# Shared facts for the kanbei guest agent (smores56/sdlc#614, part of #509).
#
# The trusted kernel runs as its own uid, neither root nor the payload uid 1000. That lets
# the virtiofs shares grant it read on the root-only inbox and write on Todo without
# giving guest root or a future same-uid sandbox either capability.
{
  coreUser = "kanbei-core";
  coreGroup = "kanbei-core";
  coreUid = 1001;
  coreGid = 1001;
}
