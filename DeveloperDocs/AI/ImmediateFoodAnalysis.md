# Immediate food analysis

The main picture-to-bolus flow has one primary prompt and one optional addendum:

1. `Streaming Food Analysis` is sent to the configured OpenRouter model immediately after image capture.
2. `Food Description Context` is sent only when the user supplies context and taps Analyze.

The immediate response contains provisional carbohydrate, fat, and protein estimates. These values are displayed below the description field, but they are not applied to the treatment form. Trio's algorithm remains the only component that calculates insulin, after the user confirms the analysis.

## Deterministic branches

| State when Analyze is tapped | Exact action |
|---|---|
| Immediate request completed; description is empty | Reuse the completed response. Do not make a second primary-model request. |
| Immediate request completed; description is present | Make a new refinement request using the same model and `session_id`. Its messages are the exact original image message, the original structured result as an assistant message, and the rendered `Food Description Context` as a user message. |
| Immediate request failed or did not produce a complete result | Retry the primary-model analysis. If a description exists, send it as a separate user addendum after the unchanged image message. |
| Multi-provider comparison is enabled | Run the configured provider immediately. Other provider tabs remain lazy and start only when selected. |

Restaurant classification and published-nutrition search remain supporting requests. When a description is present, they run alongside the confirmed/refined primary analysis and may replace matching estimates with published nutrition.

## Prompt caching

The refinement request is a new HTTP request. Its first message is produced by the same builder as the immediate request, preserving the prompt text and exact image bytes as the cacheable prefix. A stable OpenRouter `session_id` is reused for the capture. Cache hits are optional; correctness does not depend on them.

Streaming requests ask OpenRouter to include usage. `prompt_tokens_details.cached_tokens` is logged when returned so cache behavior can be measured.
