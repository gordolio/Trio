# OpenRouter Model Configuration

Trio loads the model catalog from `GET https://openrouter.ai/api/v1/models` and caches the latest successful response locally. The settings picker only offers models that advertise both image input and structured response support. Saved IDs remain configured when a model disappears from the catalog; Trio marks the model unavailable instead of substituting another model.

Users may configure one to four ordered models, choose one default, and favorite catalog entries locally. Food analysis, edits, conversation, and published-nutrition web search use the model assigned to that result tab. Restaurant and nutrition-intent classification use the separately named `OpenRouterModels.utilityModelID`, currently `openai/gpt-4o-mini`, because those operations are text-only and should remain low cost.

By default, Trio runs the default model first and starts another configured model only when its tab is opened. The `Run all models immediately` option starts every configured analysis concurrently and can increase cost.

Catalog compatibility is advisory. OpenRouter routing or model capabilities can change after a catalog refresh, so runtime failures remain isolated to the affected tab and can be retried.

Fast mode is enabled by default, including for existing settings. The AI settings screen has a `Use Fast mode` toggle. Chat completions and nutrition web search send `service_tier: "fast"` when enabled, or `"default"` when disabled. OpenRouter tries fast capacity first and can fall back to standard capacity; billing follows the tier actually served. Fast mode can cost more and does not guarantee a particular latency. The separate alpha Decisions classifier API does not receive chat-completion tier or effort parameters.

Each configured model has a reasoning effort selector when its catalog entry exposes `reasoning.supported_efforts`. Values come from that metadata, rather than a provider or model-name allowlist. An explicit `null` accepts all recognized gateway efforts; an omitted field offers no effort selection. Mandatory reasoning removes `none` (displayed as `Off`). `Model default` omits the request's reasoning override.

Effort overrides are saved per configured selection, including frontier aliases, and used for analysis, refinement, item edits, conversation, and nutrition web search. Each request validates the saved effort against the resolved model's current cached capabilities. An unavailable or no-longer-supported effort uses the model default until the user chooses a valid value. Utility text classifiers use the Fast mode setting but never inherit an analysis model's effort. Removing a model removes its effort override. Older caches are refreshed on first use to acquire reasoning metadata; their models remain available offline. The weekly refresh and pull-to-refresh both update the selectors.

Explicit effort overrides increase the completion budget to leave room for both reasoning and structured output, using OpenRouter's documented approximate reasoning allocations. Model-default and disabled reasoning retain the existing output limits. Actual reasoning allocation varies by provider; higher effort can increase response time and cost.

Protocol references: [OpenRouter service tiers](https://openrouter.ai/docs/guides/features/service-tiers) and [per-model reasoning options](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens#discovering-per-model-reasoning-options).
