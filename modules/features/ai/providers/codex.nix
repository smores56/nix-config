# Canonical Codex spec: model catalog for oh-my-pi via the built-in
# `openai-codex` provider (OAuth creds mirrored from Codex CLI). maki uses
# its built-in `openai` provider for the same models, so there's no maki
# custom-provider shape here — only the omp model refs for modelsConfig.
{ ... }:
let
  providerId = "openai-codex";

  # Codex models use omp's built-in openai-codex provider; no custom model
  # defs needed, just the refs for modelRoles / enabledModels.
  models = {
    gpt55 = "${providerId}/gpt-5.5";
    gpt55Xhigh = "${providerId}/gpt-5.5:xhigh";
    gpt54 = "${providerId}/gpt-5.4";
    gpt54Mini = "${providerId}/gpt-5.4-mini";
  };
in
{
  _module.args.aiCodex = {
    inherit providerId models;
  };
}
