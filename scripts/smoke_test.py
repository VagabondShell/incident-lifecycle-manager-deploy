import json
import sys
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import urlopen

args = sys.argv

if len(args) != 2:
    print("Usage: python3 smoke_test.py <website-url>")
    sys.exit(1)

url = args[1]
parsed_url = urlparse(url)

if parsed_url.scheme != "https" or not parsed_url.hostname:
    print("Invalid URL: expected https:// followed by a hostname")
    sys.exit(1)

health_url = url.rstrip("/") + "/api/v1/health"

try:
    with urlopen(health_url, timeout=10) as response:
        body = response.read()
        data = json.loads(body)

        if (
            response.status != 200
            or data["status"] != "ok"
            or data["details"]["database"]["status"] != "up"
        ):
            print("FAIL: backend or database is unhealthy")
            sys.exit(1)
    with urlopen(url, timeout=10) as response:
        if response.status != 200:
            print("FAIL: nginx or frtonend is unhealthy")
            sys.exit(1)

except HTTPError as error:
    print(f"FAIL: {error.url} returned HTTP {error.code}")
    sys.exit(1)

except URLError as error:
    print(f"FAIL: connection failed: {error.reason}")
    sys.exit(1)

except (TimeoutError, OSError, HTTPException) as error:
    print(f"FAIL: network request failed: {error}")
    sys.exit(1)

except (ValueError, KeyError, TypeError) as error:
    print(f"FAIL: unexpected health response: {error}")
    sys.exit(1)

print("PASS: backend, database, and frontend HTTP checks")
