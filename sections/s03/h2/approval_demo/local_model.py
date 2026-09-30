"""Deterministic Strands model for an offline, credential-free tool exercise."""

from __future__ import annotations

import json
from collections.abc import AsyncIterable
from typing import Any

from strands.models import Model


class LocalToolModel(Model):
    """Select a known tool deterministically; it is not a language model."""

    def __init__(self, tool_name: str, arguments: dict[str, Any]) -> None:
        self.config = {"model_id": "local-deterministic-training-model"}
        self.tool_name = tool_name
        self.arguments = arguments

    def update_config(self, **model_config: Any) -> None:
        self.config.update(model_config)

    def get_config(self) -> dict[str, Any]:
        return dict(self.config)

    async def structured_output(self, output_model, prompt, system_prompt=None, **kwargs):
        raise NotImplementedError("structured output is outside this hands-on")
        yield  # pragma: no cover

    async def stream(self, messages, tool_specs=None, system_prompt=None, **kwargs) -> AsyncIterable[dict]:
        has_tool_result = any("toolResult" in block for message in messages for block in message.get("content", []))
        yield {"messageStart": {"role": "assistant"}}
        if not has_tool_result:
            yield {
                "contentBlockStart": {
                    "contentBlockIndex": 0,
                    "start": {"toolUse": {"name": self.tool_name, "toolUseId": "local-tool-use-1"}},
                }
            }
            yield {
                "contentBlockDelta": {
                    "contentBlockIndex": 0,
                    "delta": {"toolUse": {"input": json.dumps(self.arguments, ensure_ascii=False)}},
                }
            }
            yield {"contentBlockStop": {"contentBlockIndex": 0}}
            yield {"messageStop": {"stopReason": "tool_use"}}
        else:
            yield {"contentBlockStart": {"contentBlockIndex": 0, "start": {}}}
            yield {
                "contentBlockDelta": {
                    "contentBlockIndex": 0,
                    "delta": {"text": "ツール結果を確認しました。"},
                }
            }
            yield {"contentBlockStop": {"contentBlockIndex": 0}}
            yield {"messageStop": {"stopReason": "end_turn"}}
        yield {"metadata": {"usage": {"inputTokens": 0, "outputTokens": 0, "totalTokens": 0}}}
