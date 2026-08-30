# Canonical provider specs: model catalogs, pricing, and projections for
# maki provider scripts. Injected as a single `aiProviders` attrset so
# consumers never import individual providers.
#
# Each provider exports:
#   providerId    — slug used as the maki provider-script name ("neuralwatt")
#   models        — full model catalog (provider-specific shape)
#   selectedModels — subset projected into makiModels
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
    m:
    let
      p = getPricing m;
    in
    {
      inherit (m) id;
      context_window = m.context;
      max_output_tokens = m.output;
      pricing = {
        inherit (p) input output;
        cache_write = p.cacheWrite;
        cache_read = p.cacheRead;
      };
    };

  # ── Neuralwatt ────────────────────────────────────────────────────────────
  neuralwattModels = {
    glm53 = mkModel "glm-5.3" "GLM 5.3" 1048560 32768 true 1.45 4.50 0.145;
    deepseekV4Flash =
      mkModel "deepseek-v4-flash" "DeepSeek V4 Flash" 1048560 65536 true 0.14 0.28
        0.028;
    deepseekV4FlashFlex =
      mkModel "deepseek-v4-flash-flex" "DeepSeek V4 Flash (flex)" 1048560 65536 true 0.14 0.28
        0.028;
    # Preview model (early access); absent from the public /v1/models scope.
    qwen3827b = mkModel "qwen-3.8-27b" "Qwen 3.8 27B" 262144 32768 true 0.45 3.20 0.25;
  };

  neuralwatt = rec {
    providerId = "neuralwatt";
    models = neuralwattModels;
    baseUrl = "https://api.neuralwatt.com/v1";
    keyEnv = "NEURALWATT_API_KEY";
    makiModels = map mkMakiModel [
      models.glm53
      models.deepseekV4Flash
      models.deepseekV4FlashFlex
      models.qwen3827b
    ];
  };

  # ── Cloudflare Workers AI ─────────────────────────────────────────────────
  # CF model ids are namespaced (@cf/...). The account id is interpolated
  # into baseUrl at runtime (maki dynamicBaseUrl), keeping it out of the
  # Nix store.
  # granite-4.0-h-micro is a 3B function-calling-native model at $0.017/$0.112,
  # making it suitable for high-volume mechanical work (search/grep/read/summarize/format).
  # gpt-oss-20b was rejected because its reasoning makes it too slow and pricey for that work.
  # glm-4.7-flash / gemma-4-26b were rejected — workers-sdk #13333 breaks
  # their tool-call args on CF, and glm-4.7-flash also stalls (200/0-byte).
  cloudflareModels = {
    glm53Flash = {
      id = "@cf/zai-org/glm-5.3-flash";
      name = "GLM 5.3 Flash (Cloudflare)";
      reasoning = true;
      context = 1048576;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 0.15;
        output = 0.50;
        cacheRead = 0.03;
        cacheWrite = 0.0;
      };
    };
    glm53 = {
      id = "@cf/zai-org/glm-5.3";
      name = "GLM 5.3 (Cloudflare)";
      reasoning = true;
      context = 1048576;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 1.40;
        output = 4.40;
        cacheRead = 0.26;
        cacheWrite = 0.0;
      };
    };
    deepseekV4Flash = {
      id = "@cf/deepseek-ai/deepseek-v4-flash-0731";
      name = "DeepSeek V4 Flash (Cloudflare)";
      reasoning = true;
      context = 1310720;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 0.44;
        output = 1.32;
        cacheRead = 0.014;
        cacheWrite = 0.0;
      };
    };
    deepseekV4Pro = {
      id = "@cf/deepseek-ai/deepseek-v4-pro-0813";
      name = "DeepSeek V4 Pro (Cloudflare)";
      reasoning = true;
      context = 1048576;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 1.32;
        output = 3.96;
        cacheRead = 0.044;
        cacheWrite = 0.0;
      };
    };
    qwen3827b = {
      id = "@cf/qwen/qwen3.8-27b";
      name = "Qwen 3.8 27B (Cloudflare)";
      reasoning = true;
      context = 262144;
      output = 32768;
      input = [
        "text"
        "image"
      ];
      pricing = {
        input = 0.45;
        output = 3.20;
        # No published cached rate; price cached reads as input (conservative).
        cacheRead = 0.45;
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
        output = 0.112;
        # No published cached rate; price cached reads as input (conservative).
        cacheRead = 0.017;
        cacheWrite = 0.0;
      };
    };
  };

  cloudflare = rec {
    providerId = "cloudflare";
    models = cloudflareModels;
    selectedModels = [
      models.glm53Flash
      models.glm53
      models.deepseekV4Flash
      models.deepseekV4Pro
      models.qwen3827b
      models.graniteMicro
    ];
    keyEnv = "CLOUDFLARE_API_KEY";
    extraAuthEnv = [ "CLOUDFLARE_ACCOUNT_ID" ];
    # baseUrl placeholder — maki uses shell \${CLOUDFLARE_ACCOUNT_ID} expanded at runtime.
    makiBaseUrl = "https://api.cloudflare.com/client/v4/accounts/\${CLOUDFLARE_ACCOUNT_ID}/ai/v1";
    makiModels = map mkMakiModel selectedModels;
  };

  # ── Smortress ─────────────────────────────────────────────────────────────
  # Local network provider; no auth needed (keyEnv = null).
  smortressModels = {
    qwen38 = mkModel "qwen3.8-27b" "Qwen3.8 27B uncensored (smortress)" 200192 200192 true 0.0 0.0 0.0;
  };

  smortress = rec {
    providerId = "smortress";
    models = smortressModels;
    selectedModels = [
      models.qwen38
    ];
    baseUrl = "http://smortress:8081/v1";
    keyEnv = null;
    makiModels = map mkMakiModel selectedModels;
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
