{ ... }:
let
  model = id: name: context: output: reasoning: {
    inherit
      id
      name
      context
      output
      reasoning
      ;
  };

  models = {
    v4Pro = model "deepseek-v4-pro" "DeepSeek V4 Pro" 1000000 131072 true;
    v4Flash = model "deepseek-v4-flash" "DeepSeek V4 Flash" 1000000 131072 false;
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

  ompModelAttrs = model: {
    id = model.id;
    name = model.name;
    reasoning = model.reasoning;
    input = [ "text" ];
    contextWindow = model.context;
    maxTokens = model.output;
    cost = {
      input = 0;
      output = 0;
      cacheRead = 0;
      cacheWrite = 0;
    };
    compat = {
      supportsDeveloperRole = false;
    };
  };

in
{
  _module.args.aiDeepseek = {
    inherit
      models
      providerId
      roles
      selectedModels
      ;

    baseUrl = "https://api.deepseek.com/v1";

    ompModelsList = map ompModelAttrs selectedModels;
  };
}
