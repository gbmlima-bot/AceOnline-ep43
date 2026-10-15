#!/usr/bin/env python3
"""The health port is internal; never send credentials or connect via a proxy."""
import os
import sys
import urllib.request

try:
    port = int(os.environ.get("ACE_HEALTH_PORT", "9081"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://127.0.0.1:{port}/readyz", timeout=2) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:
    sys.exit(1)
