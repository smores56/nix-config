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
    glm51 = model "glm-5.1" "GLM 5.1" 202752 202752 true;
  };

  providerId = "crofai";
  modelRef = model: "${providerId}/${model.id}";

  roles = {
    default = modelRef models.glm51;
    slow = modelRef models.glm51;
    plan = modelRef models.glm51;
    smol = modelRef models.glm51;
    vision = modelRef models.glm51;
    designer = modelRef models.glm51;
    commit = modelRef models.glm51;
    task = modelRef models.glm51;
  };

  selectedModels = [
    models.glm51
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
