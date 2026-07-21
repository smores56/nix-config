# Canonical provider specs: model catalogs, pricing, and projections for
# maki provider scripts. Injected as a single `aiProviders` attrset so
# consumers never import individual providers.
#
# Each provider exports:
#   providerId    — slug used in model refs ("neuralwatt/glm-5.2")
#   models        — full model catalog (provider-specific shape)
#   roles         — model refs keyed by tier/role
#   selectedModels — subset exposed to maki
#   makiModels    — models in maki provider-script shape
#   baseUrl/keyEnv/extraAuthEnv — auth/connection params
{ ... }:
let
  # ── Shared helpers ─────────────────────────────────────────────────────────
  # Unified model constructor: cachePrice is explicit (DeepSeek passes inPrice as cachePrice).
  mkModel = id: name: context: output: reasoning: inPrice: outPrice: cachePrice: {
    inherit
      id
      name
      context
      output
      reasoning
      inPrice
      outPrice
      cachePrice
      ;
  };

  # Pricing accessor: handles both flat-pricing (inPrice/outPrice/cachePrice)
  # and nested-pricing (m.pricing.input/output/cacheRead/cacheWrite) models.
  getPricing =
    m:
    if m ? pricing then
      m.pricing
    else
      {
        input = m.inPrice;
        output = m.outPrice;
        cacheRead = m.cachePrice;
        cacheWrite = 0;
      };

  # Maps any model record to maki provider-script shape.
  mkMakiModel =
    m: tier:
    let
      p = getPricing m;
    in
    {
      inherit (m) id;
      inherit tier;
      context_window = m.context;
      max_output_tokens = m.output;
      pricing = {
        inherit (p) input output;
        cache_write = p.cacheWrite;
        cache_read = p.cacheRead;
      };
    };

  # ── Neuralwatt ────────────────────────────────────────────────────────────
  # Ordering matters for maki's starts_with prefix matching — longer/suffixed
  # ids must precede their prefix (e.g. glm-5.2-short-fast before glm-5.2).
  neuralwattModels = {
    glm52 = mkModel "glm-5.2" "GLM 5.2" 1048576 32768 true 1.45 4.50 0.3625;
    glm52Fast = mkModel "glm-5.2-fast" "GLM 5.2 (fast)" 1048576 32768 false 1.45 4.50 0.3625;
    glm52Short = mkModel "glm-5.2-short" "GLM 5.2 (short)" 200000 32768 true 1.45 4.50 0.3625;
    glm52ShortFast =
      mkModel "glm-5.2-short-fast" "GLM 5.2 (short, fast)" 200000 32768 false 1.45 4.50
        0.3625;
    kimiK26 = mkModel "kimi-k2.6" "Kimi K2.6" 262144 32768 true 0.69 3.22 0.1725;
    kimiK26Fast = mkModel "kimi-k2.6-fast" "Kimi K2.6 Fast" 262144 32768 false 0.69 3.22 0.1725;
    kimiK27Code = mkModel "kimi-k2.7-code" "Kimi K2.7 Code" 262144 32768 true 0.95 4.00 0.2375;
    qwen35 = mkModel "qwen3.5-397b" "Qwen3.5 397B" 262144 32768 true 0.69 4.14 0.1725;
    qwen35Fast = mkModel "qwen3.5-397b-fast" "Qwen3.5 397B Fast" 262144 32768 false 0.69 4.14 0.1725;
    qwen36 = mkModel "qwen3.6-35b" "Qwen3.6 35B" 131072 16384 true 0.29 1.15 0.0725;
    qwen36Fast = mkModel "qwen3.6-35b-fast" "Qwen3.6 35B Fast" 131072 16384 false 0.29 1.15 0.0725;
  };

  # Tiers track active MoE parameters per token:
  #   strong  = GLM-5.2 (744B/40B active), Kimi K2.6/K2.7 (1T/32B active)
  #   medium  = Qwen3.5-397B (397B/17B active)
  #   weak    = Qwen3.6-35B (35B/3B active)
  neuralwattTier =
    m:
    if builtins.match "glm-5.2.*|kimi-k2.*" m.id != null then
      "strong"
    else if builtins.match "qwen3.5.*" m.id != null then
      "medium"
    else
      "weak";

  neuralwatt = rec {
    providerId = "neuralwatt";
    models = neuralwattModels;
    modelRef = m: "${providerId}/${m.id}";
    roles = {
      default = modelRef models.glm52;
      slow = modelRef models.glm52;
      plan = modelRef models.glm52;
      smol = modelRef models.qwen36Fast;
      vision = modelRef models.qwen36Fast;
      designer = modelRef models.qwen36Fast;
      commit = modelRef models.glm52ShortFast;
      task = modelRef models.glm52ShortFast;
    };
    selectedModels = [
      models.glm52
      models.glm52ShortFast
      models.qwen36Fast
    ];
    baseUrl = "https://api.neuralwatt.com/v1";
    keyEnv = "NEURALWATT_API_KEY";
    # Full catalog (maki exposes all selectable models), ordered for prefix matching.
    makiModels = map (m: mkMakiModel m (neuralwattTier m)) [
      models.glm52ShortFast
      models.glm52Short
      models.glm52Fast
      models.glm52
      models.kimiK27Code
      models.kimiK26Fast
      models.kimiK26
      models.qwen35Fast
      models.qwen35
      models.qwen36Fast
      models.qwen36
    ];
  };

  # ── Cloudflare Workers AI ─────────────────────────────────────────────────
  # CF model ids are namespaced (@cf/...). The account id is interpolated
  # into baseUrl at runtime (maki dynamicBaseUrl), keeping it out of the
  # Nix store.
  # Three-tier cascade: GLM-5.2 strong, gpt-oss-120b medium,
  # granite-4.0-h-micro weak. The weak tier is high-volume mechanical work
  # (search/grep/read/summarize/format): it needs cheap, fast, reliable
  # function calling, not reasoning. granite-4.0-h-micro is a 3B FC-native
  # model at $0.017/$0.11 — no known CF serving bug. gpt-oss-20b (prior
  # weak pick) is a reasoning model: too slow and pricey for the tier.
  # glm-4.7-flash / gemma-4-26b were rejected — workers-sdk #13333 breaks
  # their tool-call args on CF, and glm-4.7-flash also stalls (200/0-byte).
  cloudflareModels = {
    glm52 = {
      id = "@cf/zai-org/glm-5.2";
      name = "GLM 5.2 (Cloudflare)";
      reasoning = true;
      context = 256000;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 1.40;
        output = 4.40;
        # Cloudflare auto prefix-caches; GLM-5.2 publishes a $0.26/1M cached-input rate.
        cacheRead = 0.26;
        cacheWrite = 0.0;
      };
    };
    gptOss120b = {
      id = "@cf/openai/gpt-oss-120b";
      name = "GPT OSS 120B (Cloudflare)";
      reasoning = true;
      context = 128000;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 0.35;
        output = 0.75;
        # No published cached rate; price cached reads as input (conservative).
        cacheRead = 0.35;
        cacheWrite = 0.0;
      };
    };
    graniteMicro = {
      id = "@cf/ibm-granite/granite-4.0-h-micro";
      name = "Granite 4.0 H Micro (Cloudflare)";
      reasoning = false;
      context = 131000;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 0.017;
        output = 0.11;
        # No published cached rate; price cached reads as input (conservative).
        cacheRead = 0.017;
        cacheWrite = 0.0;
      };
    };
  };

  cloudflareTier =
    m:
    if m.id == "@cf/zai-org/glm-5.2" then
      "strong"
    else if m.id == "@cf/openai/gpt-oss-120b" then
      "medium"
    else if m.id == "@cf/ibm-granite/granite-4.0-h-micro" then
      "weak"
    else
      "weak";

  cloudflare = rec {
    providerId = "cloudflare";
    models = cloudflareModels;
    modelRef = m: "${providerId}/${m.id}";
    roles = {
      default = modelRef models.glm52;
      strong = modelRef models.glm52;
      medium = modelRef models.gptOss120b;
      weak = modelRef models.graniteMicro;
    };
    selectedModels = [
      models.glm52
      models.gptOss120b
      models.graniteMicro
    ];
    keyEnv = "CLOUDFLARE_API_KEY";
    extraAuthEnv = [ "CLOUDFLARE_ACCOUNT_ID" ];
    # baseUrl placeholder — maki uses shell \${CLOUDFLARE_ACCOUNT_ID} expanded at runtime.
    makiBaseUrl = "https://api.cloudflare.com/client/v4/accounts/\${CLOUDFLARE_ACCOUNT_ID}/ai/v1";
    makiModels = map (m: mkMakiModel m (cloudflareTier m)) selectedModels;
  };

  # ── Smortress ─────────────────────────────────────────────────────────────
  # Local network provider; no auth needed (keyEnv = null).
  smortressModels = {
    gemma431b = mkModel "gemma-4-31b" "Gemma 4 31B (smortress)" 102400 102400 true 0.0 0.0 0.0;
  };

  smortress = rec {
    providerId = "smortress";
    models = smortressModels;
    modelRef = m: "${providerId}/${m.id}";
    roles = {
      default = modelRef models.gemma431b;
    };
    selectedModels = [
      models.gemma431b
    ];
    baseUrl = "http://smortress:8081/v1";
    keyEnv = null;
    makiModels = map (m: mkMakiModel m "medium") selectedModels;
  };
in
{
  _module.args.aiProviders = {
    inherit
      neuralwatt
      cloudflare
      smortress
      ;
  };
}
