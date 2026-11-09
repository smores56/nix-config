# Provider specs for maki's providers.toml, injected as `aiProviders`.
{ lib, ... }:
let
  ports = import ../../ports.nix;
  # maki's llama-cpp adapter spells thinking as `thinking_budget_tokens`: 0 off,
  # -1 adaptive, an effort level is its percent of half the output window
  # (floor 1024). A custom openai entry only thinks through declared
  # thinking_fields, so declare every level.
  minThinkingBudget = 1024;
  effortPercents = {
    minimal = 10;
    low = 20;
    medium = 40;
    high = 60;
    xhigh = 80;
    max = 100;
  };
  budgetThinking =
    output:
    let
      maxBudget = lib.max (output / 2) minThinkingBudget;
      levelBudget = pct: lib.max minThinkingBudget (maxBudget * pct / 100);
    in
    {
      off.thinking_budget_tokens = 0;
      adaptive.thinking_budget_tokens = -1;
    }
    // lib.mapAttrs (_: pct: { thinking_budget_tokens = levelBudget pct; }) effortPercents;

  # Prices are $/M tokens. reasoning defaults true and write-cache credit is
  # 0 for every model, so specs only state what differs.
  mkModel =
    {
      id,
      context,
      output,
      reasoning ? true,
      vision ? false,
      prompt,
      completion,
      cacheRead ? 0,
    }:
    {
      inherit id;
      context_window = context;
      max_output_tokens = output;
      supports_thinking = reasoning;
      # A custom openai-protocol entry reports no vision unless declared, so
      # image input and view_image stay off without it.
      supports_vision = vision;
      pricing_input = prompt;
      pricing_output = completion;
      pricing_cache_write = 0;
      pricing_cache_read = cacheRead;
    }
    // lib.optionalAttrs reasoning { thinking_fields = budgetThinking output; };

  # No per-model effort pinning: maki's always_thinking="max" picks the level.
  deepseekFlashModel = mkModel {
    id = "deepseek-v4.1-flash";
    context = 1048576;
    output = 393216;
    vision = true;
    prompt = 0.15;
    completion = 0.60;
    cacheRead = 0.02;
  };

  # Neuralwatt maps `reasoning_effort` per model, and Kimi K3.1 Pro takes the
  # full public scale, so spell the effort names instead of a token budget.
  # Omitting adaptive leaves the request silent, which keeps the model default.
  kimiProModel =
    (mkModel {
      id = "kimi-k3.1-pro";
      context = 1048576;
      # No separate output cap: completion shares the 1M window.
      output = 1048576;
      vision = true;
      prompt = 2.00;
      completion = 10.00;
      cacheRead = 0.20;
    })
    // {
      thinking_fields = {
        off.reasoning_effort = "none";
        minimal.reasoning_effort = "low";
        low.reasoning_effort = "low";
        medium.reasoning_effort = "medium";
        high.reasoning_effort = "high";
        xhigh.reasoning_effort = "max";
        max.reasoning_effort = "max";
      };
    };

  neuralwatt = {
    providerId = "neuralwatt";
    baseUrl = "https://api.neuralwatt.com/v1";
    keyEnv = "NEURALWATT_API_KEY";
    # Memory extraction reads this so Graphiti and maki agree on the model id.
    models.deepseekFlash = deepseekFlashModel;
    # Windows are the upstream caps. Both models report vision upstream; maki
    # only learns that from the flag.
    makiModels = [
      deepseekFlashModel
      (mkModel {
        id = "qwen-3.8-27b";
        context = 262144;
        output = 131072;
        vision = true;
        prompt = 0.45;
        completion = 3.20;
        cacheRead = 0.25;
      })
      kimiProModel
    ];
  };

  # models.qwen38 feeds the default model in nixos/llm.nix.
  qwen38Model = mkModel {
    id = "qwen3.8-27b";
    context = 200192;
    output = 200192;
    # nixos/llm.nix loads the base checkpoint's qwen3vl projector.
    vision = true;
    prompt = 0.0;
    completion = 0.0;
  };

  # Single source for the NixOS listener, the tunnel ingress and the client URL.
  llmPort = ports.llm;

  smortress = {
    providerId = "smortress";
    models.qwen38 = qwen38Model;
    # Always loopback (local on the server, a cloudflared forward on clients):
    # no DNS to fall through to a look-alike host.
    port = llmPort;
    baseUrl = "http://127.0.0.1:${toString llmPort}/v1";
    makiModels = [ qwen38Model ];
  };
in
{
  _module.args.aiProviders = {
    inherit
      neuralwatt
      smortress
      ;
  };
}
