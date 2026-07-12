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
    url = f"http://{ha_host}:{ha_port}/api/config/config_entries/entry?domain=wyoming"
    try:
        body = json.dumps({}).encode("utf-8")
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            entries = json.loads(resp.read())
        # Each entry has 'data' field with host/port
        for entry in entries:
            data = entry.get("data", {})
            entry_host = data.get("host", "")
            entry_port = data.get("port", 0)
            if entry_host == host and entry_port == port:
                return True
    except Exception:
        pass
    return False


def add_wyoming_via_rest(ha_host, ha_port, token, host, port, service_type):
    """Add a Wyoming service via the HA REST config flow API."""
    # Check if already configured before starting a new flow
    if is_wyoming_configured(ha_host, ha_port, token, host, port):
        print(f"  [OK] Wyoming {service_type} already configured at {host}:{port}")
        return True

    base = f"http://{ha_host}:{ha_port}/api/config/config_entries"

    # Step 1: Start flow
    print(f"  Starting Wyoming flow for {service_type}...")

    # Clean up any abandoned flows first
    try:
        progress_url = f"http://{ha_host}:{ha_port}/api/config/config_entries/flow"
        # GET current flows in progress
        req = urllib.request.Request(
            progress_url,
            headers={"Authorization": f"Bearer {token}"},
            method="GET",
        )
        # We don't actually need to clean up — just proceed
    except Exception:
        pass

    result = rest_post(f"{base}/flow", {"handler": "wyoming"}, token)

    if result.get("type") == "create_entry":
        print(f"  [OK] Wyoming {service_type} already configured")
        return True

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

async def ws_command(ws, msg_id, msg_type, **kwargs):
    await ws.send(json.dumps({"id": msg_id, "type": msg_type, **kwargs}))


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
    await ws_command(ws, 1, "auth", access_token=token)
    msg = await ws_recv(ws)
    if msg.get("type") != "auth_ok":
        raise RuntimeError(f"Auth failed: {msg}")
    return ws


async def find_wyoming_engine(ws, domain):
    """Find Wyoming engine entity IDs by scanning states for whisper/piper."""
    states = await ws_call(ws, 200, "get_states")
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


async def create_pipeline(ws, stt_engine, tts_engine, language="ru"):
    """Create or update a voice assistant pipeline via WebSocket."""
    pipelines_result = await ws_call(ws, 300, "assist_pipeline/pipeline/list")
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
        result = await ws_call(ws, 301, "assist_pipeline/pipeline/create", **pipeline_data)
        pipeline_id = result.get("id")
        print(f"  [OK] Pipeline created with id={pipeline_id}")
    else:
        await ws_call(ws, 301, "assist_pipeline/pipeline/update",
                      pipeline_id=pipeline_id, **pipeline_data)
        print(f"  [OK] Pipeline updated: {pipeline_id}")

    if preferred != pipeline_id:
        await ws_call(ws, 302, "assist_pipeline/pipeline/set_preferred",
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

    # Step 1: Add Wyoming via REST API (no websockets dependency needed here)
    print(f"Adding Wyoming integrations via REST API at {ha_host}:{ha_port}...")

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

    # Wait for HA to register newly added Wyoming entities (poll up to 30 sec)
    print("\n--- Discovering STT/TTS engines (waiting for Wyoming entities)...")
    stt_engines = []
    tts_engines = []
    for attempt in range(30):
        stt_engines = await find_wyoming_engine(ws, "stt")
        tts_engines = await find_wyoming_engine(ws, "tts")
        if stt_engines and tts_engines:
            break
        if attempt == 0 or attempt % 5 == 4:
            print(f"  Waiting for STT/TTS registration (attempt {attempt + 1}/30)...")
        time.sleep(1)

    if not stt_engines:
        all_stt = [s["entity_id"] for s in (await ws_call(ws, 210, "get_states"))
                   if s["entity_id"].startswith("stt.")]
        stt_engines = all_stt
        if not stt_engines:
            print("  [WARN] No STT engines found after 30 seconds!")

    if not tts_engines:
        all_tts = [s["entity_id"] for s in (await ws_call(ws, 211, "get_states"))
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
        pipeline_id = await create_pipeline(ws, stt_engine, tts_engine, language)
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
