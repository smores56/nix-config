{ lib, ... }:
let
  model = id: name: quantization: context: output: input: reasoning: requestCost: {
    inherit
      id
      name
      quantization
      context
      output
      input
      reasoning
      requestCost
      ;
  };

  models = {
    glm51 = model "glm-5.1" "CrofAI GLM 5.1" "Q6_K" 202752 202752 [ "text" ] true "1";
    deepseekV4Pro = model "deepseek-v4-pro" "CrofAI DeepSeek V4 Pro" "Q6_K" 1000000 131072 [
      "text"
    ] true "1";
    deepseekV4Flash = model "deepseek-v4-flash" "CrofAI DeepSeek V4 Flash" "Q6_K" 1000000 131072 [
      "text"
    ] true "0.75";
    glm47Flash = model "glm-4.7-flash" "CrofAI GLM 4.7 Flash" "fp8" 202752 131072 [
      "text"
    ] false "0.5";
    minimaxM25 = model "minimax-m2.5" "CrofAI MiniMax M2.5" "Q4_K_M" 205000 32768 [
      "text"
    ] false "0.11";
    kimiK26 = model "kimi-k2.6" "CrofAI Kimi K2.6" "Q3_K_L" 262144 262144 [
      "text"
      "image"
    ] true "1";
  };

  providerId = "crofai";
  modelRef = model: "${providerId}/${model.id}";

  roles = {
    default = modelRef models.glm51;
    slow = modelRef models.deepseekV4Pro;
    plan = modelRef models.glm51;
    smol = modelRef models.glm47Flash;
    vision = modelRef models.kimiK26;
    designer = modelRef models.kimiK26;
    commit = modelRef models.glm47Flash;
    task = modelRef models.deepseekV4Flash;
  };

  selectedModels = [
    models.glm51
    models.deepseekV4Pro
    models.deepseekV4Flash
    models.glm47Flash
    models.minimaxM25
    models.kimiK26
  ];

  opencodeModel = model: {
    name = model.name;
    limit = {
      context = model.context;
      output = model.output;
    };
  };

  ompModelYaml =
    model:
    lib.concatStringsSep "\n" [
      "      - id: ${model.id}"
      "        name: ${model.name}"
      "        reasoning: ${lib.boolToString model.reasoning}"
      "        input: [${lib.concatStringsSep ", " model.input}]"
      "        contextWindow: ${toString model.context}"
      "        maxTokens: ${toString model.output}"
      "        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }"
      "        compat: { supportsDeveloperRole: false }"
    ]
    + "\n";

  roleYaml = name: modelRef: "  ${name}: ${modelRef}";
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

    opencodeModels = builtins.listToAttrs (
      map (model: {
        name = model.id;
        value = opencodeModel model;
      }) selectedModels
    );

    ompModelsYaml = lib.concatStringsSep "" (map ompModelYaml selectedModels);
    ompModelRolesYaml = lib.concatStringsSep "\n" (
      map (name: roleYaml name roles.${name}) [
        "default"
        "slow"
        "plan"
        "smol"
        "vision"
        "designer"
        "commit"
        "task"
      ]
    );
  };
}
