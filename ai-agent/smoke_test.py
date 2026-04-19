# Smoke test: Run the agent non-interactively against live backends
# Uses Weather Function (public Azure endpoint) + MCP server (local Docker on :8080)

import os
import sys

# Point MCP to local Docker
os.environ["MCP_BASE_URL"] = "http://localhost:8080"

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))

from agent import run_agent

queries = [
    "What's the weather like in Tokyo right now?",
    "What time is it in PST?",
    "Give me a 3-day forecast for London and tell me what day of the week today is.",
]

for i, q in enumerate(queries, 1):
    print(f"\n{'='*60}")
    print(f"Query {i}: {q}")
    print("=" * 60)
    try:
        reply, _ = run_agent(q)
        print(f"\nAssistant: {reply}")
    except Exception as e:
        print(f"\nERROR: {e}")
    print()
