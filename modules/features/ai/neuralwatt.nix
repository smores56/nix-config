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
    glm52 = model "glm-5.2" "GLM 5.2" 1048576 32768 true;
    glm52Short = model "glm-5.2-short" "GLM 5.2 (short)" 200000 32768 true;
    qwen35 = model "qwen3.5-397b" "Qwen3.5 397B" 262144 32768 true;
    qwen36 = model "qwen3.6-35b" "Qwen3.6 35B" 131072 16384 true;
  };

  providerId = "neuralwatt";
  modelRef = model: "${providerId}/${model.id}";

  roles = {
    default = modelRef models.glm52;
    slow = modelRef models.glm52;
    plan = modelRef models.glm52;
    smol = modelRef models.qwen36;
    vision = modelRef models.qwen36;
    designer = modelRef models.qwen36;
    commit = modelRef models.qwen36;
    task = modelRef models.qwen35;
  };

  selectedModels = [
    models.glm52
    models.qwen35
    models.qwen36
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
  _module.args.aiNeuralwatt = {
    inherit
      models
      providerId
      roles
      selectedModels
      ;

    baseUrl = "https://api.neuralwatt.com/v1";

    ompModelsList = map ompModelAttrs selectedModels;
  };
}
