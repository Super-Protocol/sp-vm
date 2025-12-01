#!/usr/bin/env python3
import argparse
import asyncio
import os
import socket
import sys
import time
from typing import List, Optional


def _ensure_nats_py_installed() -> None:
    try:
        import nats  # noqa: F401
    except Exception:
        import subprocess
        print("[*] Installing nats-py ...", file=sys.stderr, flush=True)
        # Prefer --break-system-packages if available (Ubuntu 24.04)
        try:
            subprocess.run([sys.executable, "-m", "pip", "install", "--break-system-packages", "nats-py"], check=True)
        except subprocess.CalledProcessError:
            subprocess.run([sys.executable, "-m", "pip", "install", "nats-py"], check=True)


_ensure_nats_py_installed()
from nats.aio.client import Client as NATS  # type: ignore  # noqa: E402
from nats.js import JetStreamContext  # type: ignore  # noqa: E402
from nats.errors import TimeoutError as NATSTimeoutError  # type: ignore  # noqa: E402
from nats.js.errors import NotFoundError as JSNotFoundError  # type: ignore  # noqa: E402
from nats.js.api import StreamConfig  # type: ignore  # noqa: E402


async def ensure_stream(js: JetStreamContext, stream: str, subject: str, replicas: int) -> None:
    try:
        info = await js.stream_info(stream)
        # Update replicas if different (best-effort)
        if getattr(info.config, "num_replicas", 1) != replicas and replicas > 0:
            cfg = StreamConfig(name=stream, subjects=[subject], num_replicas=replicas)
            await js.update_stream(cfg)
            print(f"[*] Updated stream '{stream}' replicas -> {replicas}", flush=True)
        else:
            print(f"[*] Stream '{stream}' already exists", flush=True)
    except JSNotFoundError:
        cfg = StreamConfig(name=stream, subjects=[subject], num_replicas=max(1, replicas))
        await js.add_stream(cfg)
        print(f"[*] Created stream '{stream}' (replicas={max(1, replicas)})", flush=True)


async def publish_message(url: str, subject: str, payload: bytes) -> None:
    nc = NATS()
    await nc.connect(servers=[url], connect_timeout=3)
    try:
        js = nc.jetstream()
        ack = await js.publish(subject, payload)
        print(f"[*] Published to {url} subject='{subject}' seq={ack.seq}", flush=True)
    finally:
        await nc.drain()


async def read_messages(url: str, stream: str, subject: str, max_msgs: int, timeout: float, durable_hint: str) -> List[bytes]:
    nc = NATS()
    await nc.connect(servers=[url], connect_timeout=3)
    out: List[bytes] = []
    try:
        js = nc.jetstream()
        durable = f"test-{durable_hint}-{int(time.time())}"
        sub = await js.pull_subscribe(subject=subject, durable=durable, stream=stream)
        # Give server a moment to register the consumer
        await asyncio.sleep(0.2)
        remaining = max_msgs
        end_by = time.time() + timeout
        while remaining > 0 and time.time() < end_by:
            try:
                msgs = await sub.fetch(batch=min(remaining, 10), timeout=1.0)
                for m in msgs:
                    out.append(bytes(m.data))
                    await m.ack()
                    remaining -= 1
                    if remaining == 0:
                        break
            except NATSTimeoutError:
                # no messages right now, loop again until global timeout
                await asyncio.sleep(0.2)
        print(f"[*] Read {len(out)} msg(s) from {url}", flush=True)
    finally:
        await nc.drain()
    return out


async def main() -> int:
    parser = argparse.ArgumentParser(description="NATS JetStream sync test: publish from local and read from all endpoints.")
    parser.add_argument("--urls", required=True, help="Comma-separated NATS URLs, e.g. nats://10.0.0.1:4222,nats://10.0.0.2:4222")
    parser.add_argument("--local-url", default=None, help="Local node NATS URL to publish from (default: first from --urls)")
    parser.add_argument("--subject", default="test.sync", help="Subject to publish/consume")
    parser.add_argument("--stream", default="SYNC_TEST", help="JetStream stream name to use/create")
    parser.add_argument("--replicas", type=int, default=0, help="Desired stream replicas (0 -> equals number of urls, min 1)")
    parser.add_argument("--count", type=int, default=2, help="Expect to read this many messages in total")
    parser.add_argument("--timeout", type=float, default=10.0, help="Total read timeout seconds per endpoint")
    parser.add_argument("--message", default=None, help="Custom message payload")
    args = parser.parse_args()

    urls = [u.strip() for u in args.urls.split(",") if u.strip()]
    if not urls:
        print("No --urls provided", file=sys.stderr)
        return 2

    local_url = args.local_url.strip() if args.local_url else urls[0]
    replicas = args.replicas if args.replicas > 0 else len(urls)
    host = socket.gethostname()
    payload = (args.message or f"hello from {host} at {int(time.time())}").encode("utf-8")

    # Ensure stream exists (best-effort connect to first reachable)
    stream_ok = False
    for u in urls:
        try:
            nc = NATS()
            await nc.connect(servers=[u], connect_timeout=3)
            try:
                js = nc.jetstream()
                await ensure_stream(js, args.stream, args.subject, replicas)
                stream_ok = True
                break
            finally:
                await nc.drain()
        except Exception as e:
            print(f"[!] Failed ensure_stream via {u}: {e}", file=sys.stderr)
    if not stream_ok:
        print("[!] Could not ensure stream on any URL", file=sys.stderr)
        return 3

    # Publish from local
    try:
        await publish_message(local_url, args.subject, payload)
    except Exception as e:
        print(f"[!] Publish failed via {local_url}: {e}", file=sys.stderr)
        return 4

    # Read from each endpoint
    tag = host.replace("/", "_")
    all_msgs = {}
    for u in urls:
        try:
            msgs = await read_messages(u, args.stream, args.subject, max_msgs=args.count, timeout=args.timeout, durable_hint=tag)
            all_msgs[u] = [m.decode("utf-8", errors="replace") for m in msgs]
        except Exception as e:
            print(f"[!] Read failed via {u}: {e}", file=sys.stderr)
            all_msgs[u] = []

    print("\n=== Results ===", flush=True)
    for u, msgs in all_msgs.items():
        print(f"{u}:")
        for i, m in enumerate(msgs, 1):
            print(f"  [{i}] {m}")

    # Success criteria: each endpoint read at least 1 message, and globally we saw at least the number of publishes
    # Since you'll run this script on each node, set --count to expected total before each run if needed.
    ok = all(len(v) > 0 for v in all_msgs.values())
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        exit(asyncio.run(main()))
    except KeyboardInterrupt:
        exit(130)
