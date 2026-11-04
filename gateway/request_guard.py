"""Remove request fields that would let a client change routing at OpenRouter.

LiteLLM forwards these fields from the request body: "extra_body" replaces the entry's
pinned provider object (host, fallbacks, zero data retention), and "models", "route" and
"transforms" are passed on to OpenRouter, where "models" is a fallback list that can reach
models outside the allowlist. "provider" and "fallbacks" are removed for the same reason.
The pin in gateway/config.yaml is the only routing. Loaded by LiteLLM as a callback.
"""

from litellm.integrations.custom_logger import CustomLogger

ROUTING_FIELDS = ("extra_body", "provider", "models", "route", "transforms", "fallbacks")


class RequestGuard(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        for field in ROUTING_FIELDS:
            data.pop(field, None)
        return data


request_guard = RequestGuard()
