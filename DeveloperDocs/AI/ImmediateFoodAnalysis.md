# Immediate food analysis

The main picture-to-bolus flow supports optional image decision routing. Configure it in Settings > AI > Image Classifier. Its model selection is independent of Food Analysis Models and the nutrition-label extraction model.

Image routing is experimental and disabled by default, including migration from older settings. The initial decision model is `openai/gpt-6-luna-decisions`; the initial label model is `openai/gpt-4o-mini`. No Gemini classifier is used.

## Image routing

| Decision | Immediate analysis |
|---|---|
| Routing disabled | Existing configured default model with Streaming Food Analysis. |
| Clear actual food | Configured default model with the shorter Food Image Analysis prompt. |
| Clear readable nutrition facts label | Independently selected label model with Nutrition Label Extraction. |
| Mixed image, unreadable label, menu, unrelated image, uncertain answer | Configured default model with Streaming Food Analysis. |
| Decision API failure, timeout, unavailable model, invalid response | Configured default model with Streaming Food Analysis. |
| Label extraction failure or invalid final nutrients | One fallback to the configured default with Streaming Food Analysis. |

The classifier is called once per capture through `POST /api/alpha/decisions`, with the JPEG in an inline `input_image` message array in `state` and a choice question (`nutrition_label`, `food`, `uncertain`). Routing requires a valid complete probability distribution, a winning probability of at least 0.9 and a margin of 0.2. Otherwise the result is uncertain. The request times out after 8 seconds. Label extraction uses a 20-second request timeout and 700-token output budget.

OpenRouter's catalog advertises image input for these models, but its public Decisions schema describes `state` as generic JSON and does not specify the image encoding. The inline message encoding is an experimental integration and has not been verified with live inference. A rejection falls back to normal analysis. Measure accuracy and end-to-end latency with representative labels, meals, mixed images and unreadable images before enabling by default; a classifier adds latency to food images.

Label results must contain exactly one item, confidence of at least 0.9, finite nonnegative nutrients and a positive serving count. Partial label values are withheld until validation. Nutrients stay PER SERVING as printed, with total carbohydrate rather than net carbohydrate and the printed count/unit; no multiplication by servings per container. The UI identifies the actual label model when its result is displayed under the default calculation-model tab. Chat and correction requests still use the configured calculation model.

The decision picker loads a separate weekly catalog from `/api/v1/models?output_modalities=decisions` and requires both `image` input and `decisions` output. Calculation pickers explicitly exclude decisions models. An unavailable saved selection remains visible and is not silently replaced.

The original flow has one primary prompt and one optional addendum:

1. `Streaming Food Analysis` is sent to the configured OpenRouter model immediately after image capture.
2. `Food Description Context` is sent only when the user supplies context and taps Analyze.

The immediate response contains provisional carbohydrate, fat, and protein estimates. These values are displayed below the description field, but they are not applied to the treatment form. Trio's algorithm remains the only component that calculates insulin, after the user confirms the analysis.

## Deterministic branches

| State when Analyze is tapped | Exact action |
|---|---|
| Immediate request completed; description is empty | Reuse the completed response. Do not make a second primary-model request. |
| Immediate food request completed; description is present | Make a new refinement request using the same model and `session_id`. Its messages are the exact original image message, the original structured result as an assistant message, and the rendered `Food Description Context` as a user message. |
| Immediate fast-label request completed; description is present | Run a fresh configured-default analysis with the general image prompt and description. The fast label response is not used as an estimate for consumed portions. |
| Immediate request failed or did not produce a complete result | Retry the primary-model analysis. If a description exists, send it as a separate user addendum after the unchanged image message. |
| Multi-provider comparison is enabled | Run the configured provider immediately. Other provider tabs remain lazy and start only when selected. |

Restaurant classification and published-nutrition search remain supporting requests. When a description is present, they run alongside the confirmed/refined primary analysis and may replace matching estimates with published nutrition.

## Complete query inventory

| Trigger | Calls and dependencies |
|---|---|
| Camera, photo library, or shortcut capture | Same resized JPEG capture path; normal catalog refresh when stale; optional single decision call; one immediate analysis; at most one label-to-default fallback. |
| Analyze with no description and complete immediate result | Reuse response and conversation manager; no new vision request. |
| Analyze with description | Food refinement or fresh default label-context analysis; concurrently text restaurant classification using the utility model; if positive, published nutrition web search using the configured calculation model. Search failures retain vision values. |
| Analyze after failed immediate analysis | Fresh configured-default analysis, with optional description; same restaurant/search branch when description exists. |
| Run all models immediately | Each additional configured model performs its own vision analysis and optional description-based restaurant/search requests. The image classifier is shared, never repeated. |
| Open an unqueried comparison tab | That tab's configured model performs vision analysis and optional restaurant/search requests. |
| Retry an analysis tab | Fresh request through that tab's configured calculation model with a new session; optional restaurant/search branch. No new image classification. |
| Edit one item | Single-Item Correction through that result's configured calculation model. |
| Chat about a known restaurant | Utility-model Nutrition Lookup Detection; if lookup requested, configured-model published nutrition search and local confirmation. Otherwise Conversation Refinement with the image through the configured calculation model. |
| Other chat | Configured-model Conversation Refinement, including Conversation Image Reference. |
| Change servings, select items, accept/reject published facts, confirm entry | Local transformations; no new LLM requests. |

The capture stores prompt text before asynchronous work. A unique session identifies each capture, including repeated uploads of identical bytes, and result publication checks the active session to reject stale work.

## Prompt caching

The refinement request is a new HTTP request. Its first message is produced by the same builder as the immediate request, preserving the prompt text and exact image bytes as the cacheable prefix. A stable OpenRouter `session_id` is reused for the capture. Cache hits are optional; correctness does not depend on them.

Streaming requests ask OpenRouter to include usage. `prompt_tokens_details.cached_tokens` is logged when returned so cache behavior can be measured.
