# Browser frontend for the Letta agent. Open WebUI drives the App Server's
# OpenAI-compatible API, so the agent keeps its own memory, tools and schedules while the
# browser gets a chat UI. Loopback-only; reachability is the tunnel's call.
{
  lib,
  ...
}:
let
  ports = import ../ports.nix;

  # The App Server advertises each agent as a model, named after the agent when that name
  # is unique. `DEFAULT_MODELS` must match what the picker lists, so this is the agent's
  # name and not its id: renaming the agent breaks the default.
  agentModel = "nanobot";
in
{
  services.open-webui = {
    enable = true;
    host = "127.0.0.1";
    port = ports.openWebui;
    stateDir = "/var/lib/data/open-webui";

    environment = {
      WEBUI_AUTH = "True";
      # The App Server is keyless on loopback, but Open WebUI rejects an empty key.
      OPENAI_API_BASE_URLS = "http://127.0.0.1:${toString ports.letta}/v1";
      OPENAI_API_KEYS = "none";
      DEFAULT_MODELS = agentModel;
      # Sends `X-OpenWebUI-Chat-Id`, which the App Server uses as the conversation key for
      # streaming requests. Without it every turn starts a fresh temporary conversation and
      # the agent loses the thread; with it, one Open WebUI chat is one Letta conversation
      # and MemFS is shared across all of them.
      ENABLE_FORWARD_USER_INFO_HEADERS = "True";
      # Env is authoritative; the DB must not pin an older config.
      ENABLE_PERSISTENT_CONFIG = "False";
    };
  };
  # The upstream DynamicUser keeps state under /var/lib/private behind a symlink, which
  # restic archives without following, leaving the chat database out of every snapshot.
  # A static user makes it a real directory in the backed-up tree.
  users.groups.open-webui = { };
  users.users.open-webui = {
    isSystemUser = true;
    group = "open-webui";
  };

  systemd.services.open-webui = {
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "open-webui";
      Group = "open-webui";
      StateDirectory = lib.mkForce "data/open-webui";
      StateDirectoryMode = lib.mkForce "0700";
    };
  };
}
