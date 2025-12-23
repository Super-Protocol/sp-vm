#!/usr/bin/env python3

import argparse
import base64
import json
import os
import re
import shutil
import sys
from typing import List
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from re import search as re_search
import pymysql

def require_cmd(cmd_name: str) -> None:
  if shutil.which(cmd_name) is None:
    print(f"Missing required command: {cmd_name}", file=sys.stderr)
    sys.exit(1)

def patch_pymysql_dev_server_version() -> None:
  """
  Some dev/test MySQL-compatible servers report a server_version starting with
  a non-numeric string like 'dev...', which causes PyMySQL to fail when it tries
  to parse the major version as int. Patch the authentication routine to coerce
  such versions to a sane default (e.g., '5.7.0') before the check.
  """
  try:
    original = pymysql.connections.Connection._request_authentication
  except Exception:
    return

  def _patched_request_authentication(self, *args, **kwargs):  # type: ignore[no-redef]
    try:
      raw = getattr(self, "server_version", "")
      head = str(raw).split(".", 1)[0]
      if not head.isdigit():
        setattr(self, "server_version", "5.7.0")
        if os.environ.get("SWARM_CLI_DEBUG", "0").lower() in ("1", "true", "yes"):
          print(f"[DEBUG] Patched PyMySQL server_version '{raw}' -> '5.7.0'")
    except Exception:
      pass
    return original(self, *args, **kwargs)

  pymysql.connections.Connection._request_authentication = _patched_request_authentication  # type: ignore[assignment]

def sql_quote(value: str) -> str:
  # Escape single quotes for SQL and wrap with quotes
  return "'" + value.replace("'", "''") + "'"

def filter_manifest_remove_init(manifest_text: str) -> str:
  lines = manifest_text.splitlines()
  result: List[str] = []
  inside_commands = False
  for line in lines:
    if not inside_commands and re.match(r'^commands:\s*$', line):
      inside_commands = True
      result.append(line)
      continue
    if inside_commands:
      if re.match(r'^[^\s]', line):
        inside_commands = False
      else:
        if re.match(r'^\s*-\s*init\s*$', line):
          continue
    result.append(line)
  return "\n".join(result) + ("\n" if manifest_text.endswith("\n") else "")

def create_engine_from_env(db: dict) -> Engine:
  user = db["user"]
  password = db.get("password") or ""
  pw_part = f":{password}" if password else ""
  host = db["host"]
  port = db["port"]
  name = db["name"]
  dsn = f"mysql+pymysql://{user}{pw_part}@{host}:{port}/{name}?charset=utf8mb4"
  return create_engine(dsn, pool_pre_ping=True, future=True)

def run_sql_statements(engine: Engine, statements: List[str]) -> None:
  try:
    with engine.begin() as conn:
      for stmt in statements:
        if stmt.strip():
          conn.execute(text(stmt))
  except Exception as exc:
    print(f"MySQL execution failed: {exc}", file=sys.stderr)
    sys.exit(1)

def run_sql(engine: Engine, sql: str, params: dict | None = None) -> None:
  try:
    with engine.begin() as conn:
      conn.execute(text(sql), params or {})
  except Exception as exc:
    print(f"MySQL execution failed: {exc}", file=sys.stderr)
    sys.exit(1)

def create_cluster_policies(args: argparse.Namespace, db: dict, engine: Engine) -> None:
  id_value = args.id or ""
  if not id_value:
    print("ClusterPolicies id is required.", file=sys.stderr)
    sys.exit(1)

  fields = ["id"]
  values = [id_value]
  updates = ["id=VALUES(id)"]

  if args.minSize is not None:
    fields.append("minSize")
    values.append(str(args.minSize))
    updates.append("minSize=VALUES(minSize)")
  if args.maxSize is not None:
    fields.append("maxSize")
    values.append(str(args.maxSize))
    updates.append("maxSize=VALUES(maxSize)")
  if args.maxClusters is not None:
    fields.append("maxClusters")
    values.append(str(args.maxClusters))
    updates.append("maxClusters=VALUES(maxClusters)")

  # Build parameterized SQL
  fields_csv = ",".join(fields)
  placeholders = ",".join([f":{f}" for f in fields])
  params = {fields[i]: (int(values[i]) if str(values[i]).isdigit() else values[i]) for i in range(len(fields))}
  updates_csv = ",".join(updates)

  # No debug output; keep script quiet by default

  sql = (
    f"INSERT INTO ClusterPolicies ({fields_csv}) VALUES ({placeholders})\n"
    f"ON DUPLICATE KEY UPDATE {updates_csv};\n"
  )
  run_sql(engine, sql, params)
  print(f"ClusterPolicies '{id_value}' upserted.")

def create_cluster_services(args: argparse.Namespace, db: dict, engine: Engine) -> None:
  name = args.name
  cluster_policy = args.cluster_policy
  version_raw = args.version or "1.0.0"
  location = args.location
  id_value = args.id

  if not name or not cluster_policy:
    print("ClusterServices requires --name and --cluster_policy.", file=sys.stderr)
    sys.exit(1)

  if not location:
    location = f"/etc/swarm-cloud/services/{name}"
  if not id_value:
    id_value = f"{cluster_policy}:{name}"

  manifest_content = None
  manifest_path = os.path.join(location.rstrip("/"), "manifest.yaml")
  if os.path.isfile(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as f:
      content = f.read()
    if args.omit_command_init:
      content = filter_manifest_remove_init(content)
    manifest_content = content

  # Parameterize everything; store plain YAML in 'manifest'
  # Normalize version to an integer to be compatible with INT columns.
  # - If version contains digits (e.g. 'dev', '1.0.0'), extract the first number
  # - Fallback to 0 if nothing numeric is present
  version_match = re_search(r"\d+", str(version_raw))
  version_normalized = int(version_match.group(0)) if version_match else 0
  # No debug output; keep script quiet by default

  insert_sql = (
    "INSERT INTO ClusterServices (id, cluster_policy, name, version, location, hash, manifest, updated_ts)\n"
    "VALUES (\n"
    "  :id,\n"
    "  :cluster_policy,\n"
    "  :name,\n"
    "  :version,\n"
    "  :location,\n"
    "  NULL,\n"
    "  :manifest,\n"
    "  UNIX_TIMESTAMP()*1000\n"
    ")\n"
    "ON DUPLICATE KEY UPDATE\n"
    "  version=VALUES(version),\n"
    "  location=VALUES(location),\n"
    "  manifest=VALUES(manifest),\n"
    "  updated_ts=VALUES(updated_ts);\n"
  )
  params = {
    "id": id_value,
    "cluster_policy": cluster_policy,
    "name": name,
    "version": version_normalized,
    "location": f"dir://{location}",
    "manifest": manifest_content,
  }
  run_sql(engine, insert_sql, params)
  print(f"ClusterServices '{id_value}' upserted.")


def create_swarm_secrets(args: argparse.Namespace, db: dict, engine: Engine) -> None:
  """
  Insert or keep a SwarmSecret.
  Semantics are like INSERT IGNORE: we do not overwrite existing secrets.
  """
  id_value = args.id or args.positional_id
  value = args.value

  if not id_value or value is None:
    print("SwarmSecrets requires id (positional or --id) and --value.", file=sys.stderr)
    sys.exit(1)

  insert_sql = (
    "INSERT INTO SwarmSecrets (id, value)\n"
    "VALUES (:id, :value)\n"
    "ON DUPLICATE KEY UPDATE\n"
    "  value = value;\n"
  )
  params = {
    "id": id_value,
    "value": value,
  }
  run_sql(engine, insert_sql, params)
  print(f"SwarmSecrets '{id_value}' upserted (existing values preserved).")


def get_cluster_policies(args: argparse.Namespace, db: dict, engine: Engine) -> None:
  """
  Fetch a ClusterPolicy by id.
  - Exit code 0: policy exists, JSON is printed to stdout.
  - Exit code 1: policy not found.
  - Exit code 2: query failed.
  """
  policy_id = args.id or args.positional_id
  if not policy_id:
    print("ClusterPolicies get requires id (positional or --id).", file=sys.stderr)
    sys.exit(2)

  sql = (
    "SELECT id, minSize, maxSize, maxClusters "
    "FROM ClusterPolicies WHERE id = :id LIMIT 1"
  )
  try:
    with engine.connect() as conn:
      row = conn.execute(text(sql), {"id": policy_id}).mappings().first()
  except Exception as exc:
    print(f"MySQL query failed: {exc}", file=sys.stderr)
    sys.exit(2)

  if row is None:
    # Not found — suitable for 'existence' checks in shell scripts.
    sys.exit(1)

  print(json.dumps(dict(row)))


def get_cluster_services(args: argparse.Namespace, db: dict, engine: Engine) -> None:
  """
  Fetch a ClusterService.
  Lookup order:
    - if id/positional_id is provided, search by id;
    - else, if both --cluster_policy and --name are provided, search by them.
  - Exit code 0: service exists, JSON is printed to stdout.
  - Exit code 1: service not found.
  - Exit code 2: query failed / invalid arguments.
  """
  service_id = args.id or args.positional_id
  cluster_policy = args.cluster_policy
  name = args.name

  if service_id:
    sql = (
      "SELECT id, cluster_policy, name, version, location "
      "FROM ClusterServices WHERE id = :id LIMIT 1"
    )
    params = {"id": service_id}
  elif cluster_policy and name:
    sql = (
      "SELECT id, cluster_policy, name, version, location "
      "FROM ClusterServices "
      "WHERE cluster_policy = :cluster_policy AND name = :name "
      "LIMIT 1"
    )
    params = {"cluster_policy": cluster_policy, "name": name}
  else:
    print(
      "ClusterServices get requires either id (positional/--id) "
      "or both --cluster_policy and --name.",
      file=sys.stderr,
    )
    sys.exit(2)

  try:
    with engine.connect() as conn:
      row = conn.execute(text(sql), params).mappings().first()
  except Exception as exc:
    print(f"MySQL query failed: {exc}", file=sys.stderr)
    sys.exit(2)

  if row is None:
    sys.exit(1)

  print(json.dumps(dict(row)))

def parse_args(argv: List[str]) -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Simple CLI to manage Swarm DB entities."
  )
  parser.add_argument("action", choices=["create", "get"])
  parser.add_argument("entity", choices=["ClusterPolicies", "ClusterServices", "SwarmSecrets"])
  # Positional optional id (first non-key=value), like the original script
  parser.add_argument("positional_id", nargs="?", help="Optional positional id")

  # Common optional explicit --id
  parser.add_argument("--id", dest="id")

  # ClusterPolicies options
  parser.add_argument("--minSize", type=int)
  parser.add_argument("--maxSize", type=int)
  parser.add_argument("--maxClusters", type=int)

  # ClusterServices options
  parser.add_argument("--name")
  parser.add_argument("--cluster_policy")
  parser.add_argument("--version", default=None)
  parser.add_argument("--location")
  parser.add_argument("--omit-command-init", dest="omit_command_init", action="store_true")

  # SwarmSecrets options
  parser.add_argument("--value")

  ns = parser.parse_args(argv)
  # If a positional id was provided, prefer it unless --id was set
  if ns.positional_id and not ns.id:
    ns.id = ns.positional_id
  return ns

def main(argv: List[str]) -> None:
  # Apply PyMySQL compatibility patch for non-numeric server versions
  patch_pymysql_dev_server_version()
  # Be resilient to environments where DB_PORT is set to non-numeric values (e.g. 'dev')
  port_env_raw = os.environ.get("DB_PORT", "3306")
  if not str(port_env_raw).isdigit():
    alt_port = os.environ.get("SWARM_DB_PORT") or os.environ.get("MYSQL_PORT") or "3306"
    port_env = alt_port if str(alt_port).isdigit() else "3306"
  else:
    port_env = port_env_raw

  db = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(port_env),
    "user": os.environ.get("DB_USER", "root"),
    "name": os.environ.get("DB_NAME", "swarmdb"),
    "password": os.environ.get("DB_PASSWORD", ""),
  }

  engine = create_engine_from_env(db)

  args = parse_args(argv)
  key = f"{args.action}:{args.entity}"

  if key == "create:ClusterPolicies":
    create_cluster_policies(args, db, engine)
  elif key == "create:ClusterServices":
    create_cluster_services(args, db, engine)
  elif key == "create:SwarmSecrets":
    create_swarm_secrets(args, db, engine)
  elif key == "get:ClusterPolicies":
    get_cluster_policies(args, db, engine)
  elif key == "get:ClusterServices":
    get_cluster_services(args, db, engine)
  else:
    print(f"Unsupported command: {args.action} {args.entity}", file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
  main(sys.argv[1:])
