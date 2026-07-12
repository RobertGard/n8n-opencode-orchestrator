#!/usr/bin/env python3
"""Programmatically set up Wyoming Protocol + voice pipeline in Home Assistant.

Usage:
    HA_API_TOKEN="your-token" python3 scripts/setup-wyoming.py [--ha-host 127.0.0.1] [--ha-port 8123]

Does three things without UI clicks:
1. Adds Wyoming whisper (STT, port 10300) and piper (TTS, port 10200) — via REST API
2. Creates an Assist pipeline with faster-whisper + piper + homeassistant agent — via WebSocket
3. Sets it as the preferred pipeline

Refs:
    REST:  POST /api/config/config_entries/flow  (config_entries.py)
    REST:  POST /api/config/config_entries/flow/{flow_id}  (data_entry_flow.py)
    WS:    assist_pipeline/pipeline/{list,create,update,set_preferred}  (pipeline.py)
"""

import asyncio
import json
import os
import sys
import urllib.request
import urllib.error


DEFAULT_HA_HOST = "127.0.0.1"
DEFAULT_HA_PORT = 8123
WHISPER_PORT = 10300
PIPER_PORT = 10200
PIPELINE_NAME = "Home Assistant"
CONVERSATION_ENGINE = "homeassistant"


def rest_post(url, data, token):
    """POST JSON to HA REST API, return parsed response."""
    body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            if not raw:
                return {}
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code} {err_body}") from None


def is_wyoming_configured(ha_host, ha_port, token, host, port):
    """Check if a Wyoming config entry already exists for host:port."""
    entries = _get_wyoming_entries(ha_host, ha_port, token)
    for entry in entries:
        data = entry.get("data", {})
        entry_host = data.get("host", "")
        entry_port = data.get("port", 0)
        if entry_host == host and entry_port == port:
            return True
    return False


def _get_wyoming_entries(ha_host, ha_port, token):
    """Get all Wyoming config entries."""
    url = f"http://{ha_host}:{ha_port}/api/config/config_entries/entry?domain=wyoming"
    try:
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except Exception:
        return []


def cleanup_duplicate_wyoming(ha_host, ha_port, token):
    """Remove duplicate Wyoming config entries for same host:port.
    
    Previous bootstrap runs (before idempotency check) may have created
    duplicate entries like faster_whisper_2, _3, _4. Keep one per host:port,
    delete the rest.
    """
    entries = _get_wyoming_entries(ha_host, ha_port, token)
    seen = {}  # (host, port) → entry_id
    to_delete = []

    for entry in entries:
        data = entry.get("data", {})
        key = (data.get("host", ""), data.get("port", 0))
        entry_id = entry.get("entry_id", "")
        if key in seen:
            to_delete.append(entry_id)
        else:
            seen[key] = entry_id

    if not to_delete:
        return

    print(f"\n--- Cleaning up {len(to_delete)} duplicate Wyoming entries ---")
    for entry_id in to_delete:
        try:
            url = f"http://{ha_host}:{ha_port}/api/config/config_entries/entry/{entry_id}"
            req = urllib.request.Request(
                url,
                headers={"Authorization": f"Bearer {token}"},
                method="DELETE",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                pass
            print(f"  Removed duplicate entry: {entry_id}")
        except Exception as e:
            print(f"  [WARN] Could not remove {entry_id}: {e}")


def add_wyoming_via_rest(ha_host, ha_port, token, host, port, service_type):
    """Add a Wyoming service via the HA REST config flow API."""
    # Check if already configured before starting a new flow
    if is_wyoming_configured(ha_host, ha_port, token, host, port):
        print(f"  [OK] Wyoming {service_type} already configured at {host}:{port}")
        return True

    base = f"http://{ha_host}:{ha_port}/api/config/config_entries"

    # Step 1: Start flow
    print(f"  Starting Wyoming flow for {service_type}...")
    result = rest_post(f"{base}/flow", {"handler": "wyoming"}, token)

    if result.get("type") != "form":
        print(f"  [WARN] Unexpected flow result for {service_type}: {result.get('type')}")
        return False

    flow_id = result["flow_id"]

    # Step 2: Submit host:port
    try:
        result = rest_post(f"{base}/flow/{flow_id}", {"host": host, "port": port}, token)
    except RuntimeError as e:
        print(f"  [WARN] Could not submit {host}:{port} for {service_type}: {e}")
        return False

    if result.get("type") == "create_entry":
        print(f"  [OK] Wyoming {service_type} added")
        return True

    # Step 3 (if needed): Some flow versions require protocol selection
    if result.get("type") == "form":
        try:
            result = rest_post(f"{base}/flow/{flow_id}", {"protocol": "tcp"}, token)
            if result.get("type") == "create_entry":
                print(f"  [OK] Wyoming {service_type} added")
                return True
        except RuntimeError:
            pass

    print(f"  [WARN] Wyoming {service_type} flow incomplete: {result.get('type')}")
    return False


# ---- WebSocket helpers (used after REST setup) ----

class _MsgId:
    """Monotonically increasing message ID counter."""
    def __init__(self):
        self._id = 1

    def next(self):
        current = self._id
        self._id += 1
        return current


async def ws_command(ws, msg_id, msg_type, **kwargs):
    payload = {"type": msg_type, **kwargs}
    if msg_id is not None:
        payload["id"] = msg_id
    await ws.send(json.dumps(payload))


async def ws_recv(ws):
    return json.loads(await ws.recv())


async def ws_call(ws, msg_id, msg_type, **kwargs):
    """Send a command and wait for its result."""
    await ws_command(ws, msg_id, msg_type, **kwargs)
    msg = await ws_recv(ws)
    if not msg.get("success"):
        raise RuntimeError(f"Command '{msg_type}' failed: {msg.get('error', msg)}")
    return msg["result"]


async def ha_connect(ha_host, ha_port, token):
    import websockets
    ws = await websockets.connect(f"ws://{ha_host}:{ha_port}/api/websocket")
    msg = await ws_recv(ws)
    if msg.get("type") != "auth_required":
        raise RuntimeError(f"Expected auth_required, got: {msg}")
    await ws_command(ws, None, "auth", access_token=token)  # no id in auth phase
    msg = await ws_recv(ws)
    if msg.get("type") != "auth_ok":
        raise RuntimeError(f"Auth failed: {msg}")
    return ws


async def find_wyoming_engine(ws, domain, msg_id):
    """Find Wyoming engine entity IDs by scanning states for whisper/piper."""
    states = await ws_call(ws, msg_id.next(), "get_states")
    engines = []
    for s in states:
        eid = s.get("entity_id", "")
        if not eid.startswith(f"{domain}."):
            continue
        attrs = s.get("attributes", {})
        fn = attrs.get("friendly_name", "").lower()
        if "whisper" in fn or "piper" in fn or "wyoming" in str(attrs).lower():
            engines.append(eid)
    return engines


async def create_pipeline(ws, stt_engine, tts_engine, msg_id, language="ru"):
    """Create or update a voice assistant pipeline via WebSocket."""
    pipelines_result = await ws_call(ws, msg_id.next(), "assist_pipeline/pipeline/list")
    existing = pipelines_result.get("pipelines", [])
    preferred = pipelines_result.get("preferred_pipeline")

    pipeline_data = {
        "name": PIPELINE_NAME,
        "language": language,
        "conversation_engine": CONVERSATION_ENGINE,
        "conversation_language": language,
        "stt_engine": stt_engine,
        "stt_language": language,
        "tts_engine": tts_engine,
        "tts_language": language,
        "tts_voice": None,
        "wake_word_entity": None,
        "wake_word_id": None,
        "prefer_local_intents": True,
    }

    pipeline_id = None
    for p in existing:
        if p.get("stt_engine") == stt_engine and p.get("tts_engine") == tts_engine:
            pipeline_id = p["id"]
            print(f"  [OK] Pipeline already exists: {p.get('name')}")
            break

    if pipeline_id is None:
        result = await ws_call(ws, msg_id.next(), "assist_pipeline/pipeline/create", **pipeline_data)
        pipeline_id = result.get("id")
        print(f"  [OK] Pipeline created with id={pipeline_id}")
    else:
        await ws_call(ws, msg_id.next(), "assist_pipeline/pipeline/update",
                      pipeline_id=pipeline_id, **pipeline_data)
        print(f"  [OK] Pipeline updated: {pipeline_id}")

    if preferred != pipeline_id:
        await ws_call(ws, msg_id.next(), "assist_pipeline/pipeline/set_preferred",
                      pipeline_id=pipeline_id)
        print(f"  [OK] Pipeline set as preferred")

    return pipeline_id


# ---- Main ----

async def main():
    ha_token = os.environ.get("HA_API_TOKEN", "")
    ha_host = DEFAULT_HA_HOST
    ha_port = DEFAULT_HA_PORT
    language = "ru"

    for arg in sys.argv[1:]:
        if arg.startswith("--ha-host="):
            ha_host = arg.split("=", 1)[1]
        elif arg.startswith("--ha-port="):
            ha_port = int(arg.split("=", 1)[1])
        elif arg.startswith("--ha-token="):
            ha_token = arg.split("=", 1)[1]
        elif arg.startswith("--ha-language="):
            language = arg.split("=", 1)[1]

    if not ha_token:
        print("ERROR: HA_API_TOKEN not set (use --ha-token=TOKEN)")
        sys.exit(1)

    # Step 0: Clean up duplicate Wyoming entries from previous failed runs
    cleanup_duplicate_wyoming(ha_host, ha_port, ha_token)

    # Step 1: Add Wyoming via REST API (no websockets dependency needed here)
    print(f"\nAdding Wyoming integrations via REST API at {ha_host}:{ha_port}...")

    print("\n--- Adding Wyoming whisper (STT) ---")
    stt_ok = add_wyoming_via_rest(ha_host, ha_port, ha_token, ha_host, WHISPER_PORT, "whisper")

    print("\n--- Adding Wyoming piper (TTS) ---")
    tts_ok = add_wyoming_via_rest(ha_host, ha_port, ha_token, ha_host, PIPER_PORT, "piper")

    if not stt_ok or not tts_ok:
        print("\n✗ Wyoming integration failed — cannot create pipeline")
        print("  Fall back to manual setup: HA → Settings → Devices & Services → Add Integration → Wyoming Protocol")
        return 1

    # Step 2+3: Connect via WebSocket for pipeline creation
    try:
        import websockets
    except ImportError:
        print("\n⚠ Wyoming integrations added, but websockets unavailable for pipeline creation.")
        print("  Create pipeline manually: HA → Settings → Voice assistants → Add assistant")
        print("  Use STT: faster-whisper | TTS: Piper")
        return 0

    import time

    print("\nConnecting to HA WebSocket for pipeline setup...")
    ws = None
    for ws_attempt in range(10):
        try:
            ws = await ha_connect(ha_host, ha_port, ha_token)
            break
        except Exception as e:
            if ws_attempt == 9:
                print(f"  [ERROR] WebSocket connection failed after 10 attempts: {e}")
                print("  Create pipeline manually: HA → Settings → Voice assistants → Add assistant")
                return 1
            print(f"  WebSocket attempt {ws_attempt + 1}/10 failed, retrying...")
            time.sleep(2)
    print("  [OK] Authenticated")

    msg_id = _MsgId()

    # Clean up orphaned STT/TTS entities from deleted duplicate config entries
    print("\n--- Cleaning up orphaned STT/TTS entities...")
    # Get current Wyoming config entry IDs (after duplicate cleanup)
    current_entries = _get_wyoming_entries(ha_host, ha_port, ha_token)
    current_entry_ids = {e["entry_id"] for e in current_entries if e.get("entry_id")}

    # Get all STT/TTS entities and their config_entry_id from entity registry
    try:
        registry = await ws_call(ws, msg_id.next(), "config/entity_registry/list")
    except RuntimeError:
        registry = []
    orphaned = [e for e in registry
                if e.get("platform") == "wyoming"
                and e.get("config_entry_id")
                and e["config_entry_id"] not in current_entry_ids]
    for entity in orphaned:
        eid = entity["entity_id"]
        try:
            await ws_call(ws, msg_id.next(), "config/entity_registry/remove", entity_id=eid)
            print(f"  Removed orphan entity: {eid}")
        except RuntimeError:
            print(f"  [WARN] Could not remove entity: {eid}")

    if not orphaned:
        print("  No orphaned entities found")

    # Wait for HA to register newly added Wyoming entities (poll up to 30 sec)
    print("\n--- Discovering STT/TTS engines (waiting for Wyoming entities)...")
    stt_engines = []
    tts_engines = []
    for attempt in range(30):
        stt_engines = await find_wyoming_engine(ws, "stt", msg_id)
        tts_engines = await find_wyoming_engine(ws, "tts", msg_id)
        if stt_engines and tts_engines:
            break
        if attempt == 0 or attempt % 5 == 4:
            print(f"  Waiting for STT/TTS registration (attempt {attempt + 1}/30)...")
        time.sleep(1)

    if not stt_engines:
        all_stt = [s["entity_id"] for s in (await ws_call(ws, msg_id.next(), "get_states"))
                   if s["entity_id"].startswith("stt.")]
        stt_engines = all_stt
        if not stt_engines:
            print("  [WARN] No STT engines found after 30 seconds!")

    if not tts_engines:
        all_tts = [s["entity_id"] for s in (await ws_call(ws, msg_id.next(), "get_states"))
                   if s["entity_id"].startswith("tts.")]
        tts_engines = all_tts
        if not tts_engines:
            print("  [WARN] No TTS engines found after 30 seconds!")

    print(f"  STT candidates: {stt_engines}")
    print(f"  TTS candidates: {tts_engines}")

    if not stt_engines or not tts_engines:
        await ws.close()
        print("\n⚠ Wyoming services added but engines not found. Wait and retry or create pipeline manually.")
        return 1

    stt_engine = stt_engines[0]
    tts_engine = tts_engines[0]

    print(f"\n--- Creating voice pipeline (language={language}) ---")
    print(f"  STT: {stt_engine}")
    print(f"  TTS: {tts_engine}")

    try:
        pipeline_id = await create_pipeline(ws, stt_engine, tts_engine, msg_id, language)
    except RuntimeError as e:
        await ws.close()
        print(f"\n⚠ Pipeline creation failed: {e}")
        print(f"  Create manually: HA → Settings → Voice assistants → Add assistant")
        print(f"  STT: {stt_engine} | TTS: {tts_engine}")
        return 1

    await ws.close()

    print("\n" + "=" * 50)
    print("✓ Wyoming STT/TTS + voice pipeline configured!")
    print(f"  Pipeline: {pipeline_id}")
    print(f"  STT: {stt_engine}  |  TTS: {tts_engine}")
    print("=" * 50)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
