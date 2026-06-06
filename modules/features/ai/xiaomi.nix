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
    mimoV25Pro = model "mimo-v2.5-pro" "MiMo V2.5 Pro" 1000000 131072 true;
    mimoV25 = model "mimo-v2.5" "MiMo V2.5" 1000000 131072 true;
  };

  providerId = "xiaomi";
  modelRef = model: "${providerId}/${model.id}";

  roles = {
    default = modelRef models.mimoV25Pro;
    slow = modelRef models.mimoV25Pro;
    plan = modelRef models.mimoV25Pro;
    smol = modelRef models.mimoV25;
    vision = modelRef models.mimoV25;
    designer = modelRef models.mimoV25;
    commit = modelRef models.mimoV25;
    task = modelRef models.mimoV25Pro;
  };

  selectedModels = [
    models.mimoV25Pro
    models.mimoV25
  ];

  opencodeModel = model: {
    name = model.name;
    limit = {
      context = model.context;
      output = model.output;
    };
  };

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
      supportsDeveloperRole = true;
    };
    params = {
      reasoning_effort = "high";
    };
  };

in
{
  _module.args.aiXiaomi = {
    inherit
      models
      providerId
      roles
      selectedModels
      ;

    baseUrl = "https://token-plan-sgp.xiaomimimo.com/v1";

    opencodeModels = builtins.listToAttrs (
      map (model: {
        name = model.id;
        value = opencodeModel model;
      }) selectedModels
    );

    ompModelsList = map ompModelAttrs selectedModels;
  };
}
