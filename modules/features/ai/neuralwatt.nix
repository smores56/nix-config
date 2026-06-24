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
    glm52Fast = model "glm-5.2-fast" "GLM 5.2 (fast)" 1048576 32768 false;
    glm52Short = model "glm-5.2-short" "GLM 5.2 (short)" 200000 32768 true;
    glm52ShortFast = model "glm-5.2-short-fast" "GLM 5.2 (short, fast)" 200000 32768 false;
    kimiK26 = model "kimi-k2.6" "Kimi K2.6" 262144 32768 true;
    kimiK26Fast = model "kimi-k2.6-fast" "Kimi K2.6 Fast" 262144 32768 false;
    kimiK27Code = model "kimi-k2.7-code" "Kimi K2.7 Code" 262144 32768 true;
    qwen35 = model "qwen3.5-397b" "Qwen3.5 397B" 262144 32768 true;
    qwen35Fast = model "qwen3.5-397b-fast" "Qwen3.5 397B Fast" 262144 32768 false;
    qwen36 = model "qwen3.6-35b" "Qwen3.6 35B" 131072 16384 true;
    qwen36Fast = model "qwen3.6-35b-fast" "Qwen3.6 35B Fast" 131072 16384 false;
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
