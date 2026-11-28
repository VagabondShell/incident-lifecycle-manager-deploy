import re
import sys
from pathlib import Path

REPOSITORIES = {
    "POSTGRES_IMAGE": "sofianvagabond/incident-postgres",
    "POSTGRES_BACKUP_IMAGE": "sofianvagabond/incident-postgres-backup",
    "VAULT_IMAGE": "sofianvagabond/incident-vault",
    "PROMETHEUS_IMAGE": "prom/prometheus",
    "BACKEND_IMAGE": "sofianvagabond/incident-backend",
    "FRONTEND_IMAGE": "sofianvagabond/incident-frontend",
    "GRAFANA_IMAGE": "sofianvagabond/incident-grafana",
    "WAF_IMAGE": "sofianvagabond/incident-waf",
    "POSTGRES_EXPORTER_IMAGE": "sofianvagabond/incident-postgres-exporter",
    "NODE_EXPORTER_IMAGE": "prom/node-exporter",
    "MIGRATE_IMAGE": "sofianvagabond/incident-migrate",
}


def read_manifest(filename):
    entries = {}

    for number, raw_line in enumerate(
        Path(filename).read_text().splitlines(), start=1
    ):
        line = raw_line.strip()

        if not line or line.startswith("#"):
            continue

        if "=" not in line:
            raise ValueError(f"{filename}:{number}: expected KEY=value")

        key, value = line.split("=", 1)

        if key not in REPOSITORIES:
            raise ValueError(f"{filename}:{number}: unexpected key {key}")

        if key in entries:
            raise ValueError(f"{filename}:{number}: duplicate key {key}")

        repository = re.escape(REPOSITORIES[key])
        pattern = (
            rf"{repository}"
            rf"(?::[A-Za-z0-9_][A-Za-z0-9_.-]{{0,127}}"
            rf"|@sha256:[0-9a-f]{{64}})"
        )

        if re.fullmatch(pattern, value) is None:
            raise ValueError(f"{filename}:{number}: invalid image for {key}")

        entries[key] = value

    return entries


def main():
    if len(sys.argv) != 3:
        raise ValueError("Usage: merge_images.py current.env updates.env")

    current = read_manifest(sys.argv[1])
    updates = read_manifest(sys.argv[2])

    missing = REPOSITORIES.keys() - current.keys()
    if missing:
        raise ValueError(f"Current manifest is missing: {', '.join(sorted(missing))}")

    if not updates:
        raise ValueError("Updates manifest is empty")

    candidate = {**current, **updates}

    for key in REPOSITORIES:
        print(f"{key}={candidate[key]}")


try:
    main()
except (OSError, UnicodeError, ValueError) as error:
    print(f"Manifest error: {error}", file=sys.stderr)
    sys.exit(1)
