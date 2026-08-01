# OpenRouter Model Configuration

Trio loads the model catalog from `GET https://openrouter.ai/api/v1/models` and caches the latest successful response locally. The settings picker only offers models that advertise both image input and structured response support. Saved IDs remain configured when a model disappears from the catalog; Trio marks the model unavailable instead of substituting another model.

Users may configure one to four ordered models, choose one default, and favorite catalog entries locally. Food analysis, edits, conversation, and published-nutrition web search use the model assigned to that result tab. Restaurant and nutrition-intent classification use the separately named `OpenRouterModels.utilityModelID`, currently `openai/gpt-4o-mini`, because those operations are text-only and should remain low cost.

By default, Trio runs the default model first and starts another configured model only when its tab is opened. The `Run all models immediately` option starts every configured analysis concurrently and can increase cost.

Catalog compatibility is advisory. OpenRouter routing or model capabilities can change after a catalog refresh, so runtime failures remain isolated to the affected tab and can be retried.
