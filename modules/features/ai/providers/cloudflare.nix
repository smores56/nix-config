# Canonical Cloudflare Workers AI spec: model catalog + pricing, consumed by
# both oh-my-pi (models.yml) and maki (provider scripts). The account id is
# interpolated into baseUrl at runtime (maki dynamicBaseUrl / omp placeholder
# substitution), keeping it out of the Nix store.
{ ... }:
let
  providerId = "cloudflare";

  # CF model ids are namespaced (@cf/...). Pricing is USD per 1M tokens (drives
  # maki's live per-session cost readout and the maki-cf-cost monthly rollup —
  # keep in sync with cf-cost-report.py).
  models = {
    glm52 = {
      id = "@cf/zai-org/glm-5.2";
      name = "GLM 5.2 (Cloudflare)";
      reasoning = true;
      context = 262144;
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
    gptOss20b = {
      id = "@cf/openai/gpt-oss-20b";
      name = "GPT OSS 20B (Cloudflare)";
      reasoning = true;
      context = 128000;
      output = 32768;
      input = [ "text" ];
      pricing = {
        input = 0.20;
        output = 0.30;
        cacheRead = 0.20;
        cacheWrite = 0.0;
      };
    };
  };

  modelRef = m: "${providerId}/${m.id}";

  # Three-tier cascade: GLM-5.2 strong, gpt-oss-120b medium, gpt-oss-20b weak.
  # gpt-oss-20b is the weak tier — glm-4.7-flash stalls on CF (HTTP 200,
  # zero-byte body), so gpt-oss-20b (same family, lower latency) backs the
  # cheap/utility roles instead.
  roles = {
    strong = modelRef models.glm52;
    medium = modelRef models.gptOss120b;
    weak = modelRef models.gptOss20b;
  };

  selectedModels = [
    models.glm52
    models.gptOss120b
    models.gptOss20b
  ];

  # oh-my-pi models.yml shape
  ompModelAttrs = m: {
    id = m.id;
    name = m.name;
    reasoning = m.reasoning;
    input = m.input;
    contextWindow = m.context;
    maxTokens = m.output;
    cost = {
      input = m.pricing.input;
      output = m.pricing.output;
      cacheRead = m.pricing.cacheRead;
      cacheWrite = m.pricing.cacheWrite;
    };
    compat = {
      supportsDeveloperRole = false;
    };
  };

  # maki custom-provider shape
  makiTier =
    m:
    if m.id == "@cf/zai-org/glm-5.2" then
      "strong"
    else if m.id == "@cf/openai/gpt-oss-120b" then
      "medium"
    else
      "weak";

  makiModels = map (m: {
    inherit (m) id;
    tier = makiTier m;
    context_window = m.context;
    max_output_tokens = m.output;
    pricing = m.pricing;
  }) selectedModels;

  # baseUrl placeholder — omp substitutes @CLOUDFLARE_ACCOUNT_ID@ at activation
  # write time; maki uses shell \${CLOUDFLARE_ACCOUNT_ID} expanded at runtime.
  ompBaseUrl = "https://api.cloudflare.com/client/v4/accounts/@CLOUDFLARE_ACCOUNT_ID@/ai/v1";
  makiBaseUrl = "https://api.cloudflare.com/client/v4/accounts/\${CLOUDFLARE_ACCOUNT_ID}/ai/v1";
in
{
  _module.args.aiCloudflare = {
    inherit
      providerId
      models
      roles
      selectedModels
      makiModels
      ompBaseUrl
      makiBaseUrl
      ;
    keyEnv = "CLOUDFLARE_API_KEY";
    extraAuthEnv = [ "CLOUDFLARE_ACCOUNT_ID" ];
    ompModelsList = map ompModelAttrs selectedModels;
  };
}
