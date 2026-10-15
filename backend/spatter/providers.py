"""Provider-neutral routing for Spatter cloud advice (#209). Standard library only.

``ProviderRouter`` is the single object the handler calls. It owns the active
provider and model selection, a per-attempt timeout and a bounded retry policy
for transient failures. Provider adapters are injected by the deployment; their
credentials live only in the server environment and are never part of a
request, response, exception message or log line produced here.

No provider is configured in this repository and no paid AI call is made: an
empty router reports ``configured == False`` and the handler answers 503.
"""
from __future__ import annotations

import concurrent.futures as _futures
import re
import time as _time
from dataclasses import dataclass
from typing import Callable, Dict, Mapping, Optional, Protocol, Sequence, Tuple

_MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")


class ProviderUnavailable(Exception):
    """A provider attempt failed. ``transient`` failures (timeouts, 5xx, rate
    limits at the provider) may be retried; others (bad request, auth) not."""

    def __init__(self, transient: bool = False):
        super().__init__("provider unavailable")
        self.transient = transient


class ProviderAdapter(Protocol):
    def complete(self, model: str, messages: Sequence[Mapping[str, str]]) -> Tuple[str, int]:
        """Return (reply_text, usage_units)."""


@dataclass(frozen=True)
class RouteConfig:
    provider: str
    model: str
    timeout_seconds: float = 20.0
    max_attempts: int = 2

    def validate(self, known: Sequence[str]) -> None:
        if self.provider not in known:
            raise ValueError("unknown provider")
        if not _MODEL_ID.match(self.model):
            raise ValueError("invalid model id")
        if not (0 < self.timeout_seconds <= 60):
            raise ValueError("timeout must be within (0, 60] seconds")
        if not (1 <= self.max_attempts <= 3):
            raise ValueError("max_attempts must be 1..3")


class ProviderRouter:
    """Routes one completion to the configured provider/model.

    A model or provider switch replaces the whole RouteConfig atomically; a
    request already running keeps the configuration it started with.
    """

    def __init__(self, adapters: Optional[Dict[str, ProviderAdapter]] = None,
                 config: Optional[RouteConfig] = None,
                 sleep: Callable[[float], None] = _time.sleep,
                 backoff_seconds: float = 0.5):
        self._adapters = dict(adapters or {})
        self._config: Optional[RouteConfig] = None
        self._sleep = sleep
        self._backoff = backoff_seconds
        self._pool = _futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="spatter-provider")
        if config is not None:
            self.switch(config)

    @property
    def configured(self) -> bool:
        return self._config is not None

    @property
    def route(self) -> Optional[RouteConfig]:
        return self._config

    def switch(self, config: RouteConfig) -> None:
        config.validate(tuple(self._adapters))
        self._config = config

    def disable(self) -> None:
        self._config = None

    def complete(self, messages: Sequence[Mapping[str, str]]) -> Tuple[str, int]:
        config = self._config
        if config is None:
            raise ProviderUnavailable(transient=False)
        adapter = self._adapters[config.provider]
        last_transient = False
        for attempt in range(config.max_attempts):
            if attempt:
                self._sleep(self._backoff * attempt)
            future = self._pool.submit(adapter.complete, config.model, list(messages))
            try:
                return future.result(timeout=config.timeout_seconds)
            except _futures.TimeoutError:
                # The worker thread cannot be killed; its late result is discarded.
                future.cancel()
                last_transient = True
            except ProviderUnavailable as error:
                if not error.transient:
                    raise ProviderUnavailable(transient=False) from None
                last_transient = True
            except Exception:
                # Never propagate adapter text: it may contain request or key material.
                raise ProviderUnavailable(transient=False) from None
        raise ProviderUnavailable(transient=last_transient)
