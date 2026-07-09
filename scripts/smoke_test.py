#!/usr/bin/env python3
"""Ollama smoke test through the CPU-side tunnel.

Hits the Ollama /api endpoints (NOT OpenAI /v1): checks /api/tags for the
expected models and runs a /api/generate smoke call. The Local LLM Hub CPU VM
speaks the Ollama /api protocol, so this mirrors what the app actually does.

  python3 scripts/smoke_test.py --base-url http://127.0.0.1:11434 --model qwen3.6:35b
"""
import argparse
import json
import sys
import urllib.error
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base-url", required=True, help="Ollama base URL, e.g. http://127.0.0.1:11434"
    )
    parser.add_argument("--model", required=True, help="Ollama model id to generate with")
    args = parser.parse_args()

    base = args.base_url.rstrip("/")

    # 1. /api/tags — model presence.
    try:
        with urllib.request.urlopen(base + "/api/tags", timeout=30) as response:
            tags = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError) as exc:
        print(f"/api/tags FAILED: {exc}", file=sys.stderr)
        return 1

    names = [m.get("name") for m in tags.get("models", [])]
    print("Models on the box: " + (", ".join(names) if names else "(none)"))
    if args.model not in names:
        print(
            f"Smoke test FAILED: model {args.model!r} not present in /api/tags.",
            file=sys.stderr,
        )
        return 1

    # 2. /api/generate — a tiny generation.
    payload = {
        "model": args.model,
        "prompt": "Reply with the single word OK.",
        "stream": False,
        "options": {"temperature": 0.0},
    }
    request = urllib.request.Request(
        base + "/api/generate",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError) as exc:
        print(f"/api/generate FAILED: {exc}", file=sys.stderr)
        return 1

    content = (data.get("response") or "").strip()
    print(f"generate response: {content[:200]}")
    if not content:
        print("Smoke test FAILED: empty generation.", file=sys.stderr)
        return 1
    print("Smoke test OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())