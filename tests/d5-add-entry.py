#!/usr/bin/env python3
"""Step D5 only: add a temporary entry without zero data retention to gateway/config.yaml.

Never commit the result. Undo with: git checkout gateway/config.yaml
Delete this script when D5 is done.
"""
import pathlib

p = pathlib.Path(__file__).resolve().parent.parent / "gateway" / "config.yaml"
entry = """  # TEMPORARY, step D5: an endpoint without zero data retention. Never commit.
  - model_name: zdr-negative-test
    litellm_params:
      model: openrouter/openai/gpt-oss-20b
      api_key: os.environ/RAPIDSELECTOR_OPENROUTER_KEY
      max_tokens: 16
      input_cost_per_token: 0.000000018
      output_cost_per_token: 0.00000009
      extra_body:
        provider:
          order: ["darkbloom/fp8"]
          only: ["darkbloom/fp8"]
          allow_fallbacks: false
          zdr: true
          data_collection: deny
    model_info:
      rapidselector_kind: experiment
      reasoning: true
"""
s = p.read_text()
if "zdr-negative-test" in s:
    raise SystemExit("zdr-negative-test is already in gateway/config.yaml; nothing changed")
if s.count("\nlitellm_settings:") != 1:
    raise SystemExit("cannot find where to add the entry; nothing changed")
p.write_text(s.replace("\nlitellm_settings:", "\n" + entry + "litellm_settings:", 1))
print("added zdr-negative-test to", p)
