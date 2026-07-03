# Canonical DeepSeek spec: model catalog + pricing, consumed by both
# oh-my-pi (models.yml) and maki (provider scripts) via _module.args.
# deepseek.nix existed before this; this consolidates the model defs and
# adds the maki-shape projection that maki/default.nix previously lacked.
{ ... }:
let
  # DeepSeek's API doesn't publish cached-input pricing; all reads price as
  # input (conservative — never under-counts).
  model = id: name: context: output: reasoning: inPrice: outPrice: {
    inherit
      id
      name
      context
      output
      reasoning
      inPrice
      outPrice
      ;
    cachePrice = inPrice;
  };

  models = {
    v4Pro = model "deepseek-v4-pro" "DeepSeek V4 Pro" 1000000 131072 true 1.10 4.40;
    v4Flash = model "deepseek-v4-flash" "DeepSeek V4 Flash" 1000000 131072 false 0.28 0.42;
  };

  providerId = "deepseek";
  modelRef = model: "${providerId}/${model.id}";

  roles = {
    default = modelRef models.v4Pro;
    slow = modelRef models.v4Pro;
    plan = modelRef models.v4Pro;
    smol = modelRef models.v4Flash;
    vision = modelRef models.v4Flash;
    designer = modelRef models.v4Flash;
    commit = modelRef models.v4Flash;
    task = modelRef models.v4Flash;
  };

  selectedModels = [
    models.v4Pro
    models.v4Flash
  ];

  # oh-my-pi models.yml shape
  ompModelAttrs = model: {
    id = model.id;
    name = model.name;
    reasoning = model.reasoning;
    input = [ "text" ];
    contextWindow = model.context;
    maxTokens = model.output;
    cost = {
      input = model.inPrice;
      output = model.outPrice;
      cacheRead = model.cachePrice;
      cacheWrite = 0;
    };
    compat = {
      supportsDeveloperRole = false;
    };
  };

  # maki custom-provider shape (see maki/default.nix mkProviderScript)
  makiModels = map (m: {
    inherit (m) id;
    tier = if m.reasoning then "strong" else "medium";
    context_window = m.context;
    max_output_tokens = m.output;
    pricing = {
      input = m.inPrice;
      output = m.outPrice;
      cache_write = 0.0;
      cache_read = m.cachePrice;
    };
  }) selectedModels;
in
{
  _module.args.aiDeepseek = {
    inherit
      models
      providerId
      roles
      selectedModels
      makiModels
      ;
    baseUrl = "https://api.deepseek.com/v1";
    ompModelsList = map ompModelAttrs selectedModels;
  };
}
