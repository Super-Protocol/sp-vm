#!/usr/bin/env python3

import argparse
import base64
import os
import re
import shutil
import sys
from typing import List
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

def require_cmd(cmd_name: str) -> None:
  if shutil.which(cmd_name) is None:
    print(f"Missing required command: {cmd_name}", file=sys.stderr)
    sys.exit(1)

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

  sql = (
    f"INSERT INTO ClusterPolicies ({fields_csv}) VALUES ({placeholders})\n"
    f"ON DUPLICATE KEY UPDATE {updates_csv};\n"
  )
  run_sql(engine, sql, params)
  print(f"ClusterPolicies '{id_value}' upserted.")

def create_cluster_services(args: argparse.Namespace, db: dict, engine: Engine) -> None:
  name = args.name
  cluster_policy = args.cluster_policy
  version = args.version or "1.0.0"
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
    "version": version,
    "location": f"dir://{location}",
    "manifest": manifest_content,
  }
  run_sql(engine, insert_sql, params)
  print(f"ClusterServices '{id_value}' upserted.")

def parse_args(argv: List[str]) -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Simple CLI to manage Swarm DB entities."
  )
  parser.add_argument("action", choices=["create"])
  parser.add_argument("entity", choices=["ClusterPolicies", "ClusterServices"])
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

  ns = parser.parse_args(argv)
  # If a positional id was provided, prefer it unless --id was set
  if ns.positional_id and not ns.id:
    ns.id = ns.positional_id
  return ns

def main(argv: List[str]) -> None:
  db = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("DB_PORT", "3306")),
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
  else:
    print(f"Unsupported command: {args.action} {args.entity}", file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
  main(sys.argv[1:])
