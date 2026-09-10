# Canonical provider specs: model catalogs, pricing, and projections for
# maki provider scripts. Injected as a single `aiProviders` attrset so
# consumers never import individual providers.
#
# Each provider exports:
#   providerId    — slug used as the maki provider-script name ("neuralwatt")
#   models        — full model catalog (provider-specific shape)
#   selectedModels — subset projected into makiModels
#   makiModels    — models in maki provider-script shape
#   baseUrl/keyEnv/tailnetOnly — auth/connection params
_:
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
    m.pricing or {
      input = m.inPrice;
      output = m.outPrice;
      cacheRead = m.cachePrice;
      cacheWrite = 0;
    };

  # Maps any model record to maki provider-script shape.
  # supports_thinking is projected from the model's reasoning flag; thinking_fields,
  # when present, opts a llama-cpp-base model into sending native reasoning_effort
  # instead of maki's default thinking_budget_tokens (see maki providers docs).
  mkMakiModel =
    m:
    let
      p = getPricing m;
    in
    {
      inherit (m) id;
      context_window = m.context;
      max_output_tokens = m.output;
      supports_thinking = m.reasoning;
      pricing = {
        inherit (p) input output;
        cache_write = p.cacheWrite;
        cache_read = p.cacheRead;
      };
    }
    // (if m ? thinkingFields then { thinking_fields = m.thinkingFields; } else { });

  # Pinned reasoning_effort for DeepSeek V4 Flash (standard + flex): every
  # thinking mode emits "max" — the accepted literal neuralwatt documents as
  # "Deepest reasoning" (adds an explicit maximum-effort instruction). Flex is
  # the same model with the same mapping. Omitting reasoning_effort defaults to
  # none on V4-Flash, hence the explicit pin. Declaring all modes means maki
  # never falls back to thinking_budget_tokens.
  deepseekThinkingFieldsMax = {
    off = {
      reasoning_effort = "max";
    };
    adaptive = {
      reasoning_effort = "max";
    };
    minimal = {
      reasoning_effort = "max";
    };
    low = {
      reasoning_effort = "max";
    };
    medium = {
      reasoning_effort = "max";
    };
    high = {
      reasoning_effort = "max";
    };
    xhigh = {
      reasoning_effort = "max";
    };
    max = {
      reasoning_effort = "max";
    };
  };

  # ── Neuralwatt ────────────────────────────────────────────────────────────
  neuralwattModels = {
    glm53 = mkModel "glm-5.3" "GLM 5.3" 1048560 32768 true 1.45 4.50 0.145;
    deepseekV4Flash =
      mkModel "deepseek-v4-flash" "DeepSeek V4 Flash" 1048560 65536 true 0.14 0.28 0.028
      // {
        # Baked in: always max reasoning (see deepseekThinkingFieldsMax).
        thinkingFields = deepseekThinkingFieldsMax;
      };
    deepseekV4FlashFlex =
      mkModel "deepseek-v4-flash-flex" "DeepSeek V4 Flash (flex)" 1048560 65536 true 0.14 0.28 0.028
      // {
        # Flex is the same model — same reasoning_effort mapping (docs flex-tier).
        thinkingFields = deepseekThinkingFieldsMax;
      };
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
    # Offered only when the host resolves into the tailnet (100.64.0.0/10) —
    # a disconnected tailnet must not fall back to untrusted local DNS.
    tailnetOnly = true;
    makiModels = map mkMakiModel selectedModels;
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
