"""
title: Reasoning Effort
author: Local AI Stack
description: Per-chat reasoning effort selector for models that accept reasoning_effort.
version: 1.0.0
required_open_webui_version: 0.11.0
"""

from typing import Literal, Optional

from pydantic import BaseModel, Field


class Filter:
    """Add the selected reasoning effort to every enabled chat request."""

    class Valves(BaseModel):
        priority: int = Field(
            default=0,
            description="Filter execution priority. Lower values run first.",
        )

    class UserValves(BaseModel):
        reasoning_effort: Literal["low", "medium", "xhigh"] = Field(
            default="xhigh",
            title="Reasoning effort",
            description=(
                "Low is fastest, Medium is balanced, and XHigh spends the most "
                "reasoning tokens. The selected value is saved for your user."
            ),
        )

    def __init__(self):
        self.valves = self.Valves()
        self.toggle = True

    async def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        effort = "xhigh"
        user_valves = (__user__ or {}).get("valves")

        if isinstance(user_valves, dict):
            effort = user_valves.get("reasoning_effort", effort)
        elif user_valves is not None:
            effort = getattr(user_valves, "reasoning_effort", effort)

        if effort not in {"low", "medium", "xhigh"}:
            effort = "xhigh"

        body["reasoning_effort"] = effort
        return body
