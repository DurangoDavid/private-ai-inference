#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.error
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True, help="OpenAI-compatible base URL, e.g. http://host:port/v1")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    payload = {
        "model": args.model,
        "messages": [
            {
                "role": "user",
                "content": "Write a small Python function named add that returns the sum of two numbers. Return only code.",
            }
        ],
        "temperature": 0.2,
        "max_tokens": 256,
    }
    request = urllib.request.Request(
        args.base_url.rstrip("/") + "/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {args.api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", errors="replace"), file=sys.stderr)
        return 1

    content = data["choices"][0]["message"].get("content") or ""
    print(content)

    if "def add" not in content:
        print("Smoke test failed: response did not include expected function.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
