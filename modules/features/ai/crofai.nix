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
    kimiK27Code = model "kimi-k2.7-code" "Kimi K2.7 Code" 262144 262144 true;
    glm52 = model "glm-5.2" "GLM 5.2" 1000000 131072 true;
  };

  providerId = "crofai";
  modelRef = model: "${providerId}/${model.id}";

  roles = {
    default = modelRef models.kimiK27Code;
    slow = modelRef models.kimiK27Code;
    plan = modelRef models.kimiK27Code;
    smol = modelRef models.kimiK27Code;
    vision = modelRef models.kimiK27Code;
    designer = modelRef models.kimiK27Code;
    commit = modelRef models.kimiK27Code;
    task = modelRef models.kimiK27Code;
  };

  selectedModels = [
    models.kimiK27Code
    models.glm52
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
  _module.args.aiCrofai = {
    inherit
      models
      providerId
      roles
      selectedModels
      ;

    baseUrl = "https://crof.ai/v1";

    ompModelsList = map ompModelAttrs selectedModels;
  };
}
