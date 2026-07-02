{ ... }:
let
  model = id: name: context: output: reasoning: inPrice: outPrice: cachePrice: {
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

  models = {
    glm52 = model "glm-5.2" "GLM 5.2" 1048576 32768 true 1.45 4.50 0.3625;
    glm52Fast = model "glm-5.2-fast" "GLM 5.2 (fast)" 1048576 32768 false 1.45 4.50 0.3625;
    glm52Short = model "glm-5.2-short" "GLM 5.2 (short)" 200000 32768 true 1.45 4.50 0.3625;
    glm52ShortFast =
      model "glm-5.2-short-fast" "GLM 5.2 (short, fast)" 200000 32768 false 1.45 4.50
        0.3625;
    kimiK26 = model "kimi-k2.6" "Kimi K2.6" 262144 32768 true 0.69 3.22 0.1725;
    kimiK26Fast = model "kimi-k2.6-fast" "Kimi K2.6 Fast" 262144 32768 false 0.69 3.22 0.1725;
    kimiK27Code = model "kimi-k2.7-code" "Kimi K2.7 Code" 262144 32768 true 0.95 4.00 0.2375;
    qwen35 = model "qwen3.5-397b" "Qwen3.5 397B" 262144 32768 true 0.69 4.14 0.1725;
    qwen35Fast = model "qwen3.5-397b-fast" "Qwen3.5 397B Fast" 262144 32768 false 0.69 4.14 0.1725;
    qwen36 = model "qwen3.6-35b" "Qwen3.6 35B" 131072 16384 true 0.29 1.15 0.0725;
    qwen36Fast = model "qwen3.6-35b-fast" "Qwen3.6 35B Fast" 131072 16384 false 0.29 1.15 0.0725;
  };

  providerId = "neuralwatt";
  modelRef = model: "${providerId}/${model.id}";

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
