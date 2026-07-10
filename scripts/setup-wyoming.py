#!/usr/bin/env python3
"""Programmatically set up Wyoming Protocol + voice pipeline in Home Assistant.

Usage:
    HA_API_TOKEN="your-token" python3 scripts/setup-wyoming.py [--ha-host 127.0.0.1] [--ha-port 8123]

Does three things without UI clicks:
1. Adds Wyoming whisper (STT, port 10300) and piper (TTS, port 10200) integrations
2. Creates an Assist pipeline with faster-whisper + piper + homeassistant conversation agent
3. Sets it as the preferred pipeline
"""

import asyncio
import json
import os
import sys


DEFAULT_HA_HOST = "127.0.0.1"
DEFAULT_HA_PORT = 8123
WHISPER_PORT = 10300
PIPER_PORT = 10200
PIPELINE_NAME = "Home Assistant"
CONVERSATION_ENGINE = "homeassistant"


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


async def add_wyoming_service(ws, host, port, service_type):
    """Add a Wyoming service via config flow."""
    msg_id = abs(hash(f"{service_type}_{port}")) % 10000 + 100

    result = await ws_call(ws, msg_id, "config/config_entries/flow",
                           handler="wyoming", show_advanced_options=False)

    if result.get("type") == "create_entry":
        print(f"  [OK] Wyoming {service_type} already configured")
        return True

    if result.get("type") != "form":
        print(f"  [WARN] Unexpected flow result for {service_type}: {result.get('type')}")
        return False

    flow_id = result["flow_id"]
    msg_id += 1

    try:
        result = await ws_call(ws, msg_id, "config/config_entries/flow/handle",
                               flow_id=flow_id, user_input={"host": host, "port": port})
    except RuntimeError as e:
        print(f"  [WARN] Could not submit {host}:{port} for {service_type}: {e}")
        return False

    if result.get("type") == "create_entry":
        print(f"  [OK] Wyoming {service_type} added")
        return True

    if result.get("type") == "form":
        msg_id += 1
        try:
            result = await ws_call(ws, msg_id, "config/config_entries/flow/handle",
                                   flow_id=flow_id, user_input={"protocol": "tcp"})
            if result.get("type") == "create_entry":
                print(f"  [OK] Wyoming {service_type} added")
                return True
        except RuntimeError:
            pass

    print(f"  [WARN] Wyoming {service_type} flow incomplete: {result.get('type')}")
    return False


async def find_wyoming_engine(ws, domain):
    """Find Wyoming engine entity IDs by scanning states."""
    states = await ws_call(ws, 200, "get_states")
    engines = []
    for s in states:
        eid = s.get("entity_id", "")
        attrs = s.get("attributes", {})
        # Wyoming-based entities have 'friendly_name' with 'faster-whisper' or 'piper' etc.
        is_wyoming = False
        if "friendly_name" in attrs:
            fn = attrs["friendly_name"].lower()
            if "whisper" in fn or "piper" in fn:
                is_wyoming = True
        # Also check by entity_id pattern
        if eid.startswith(f"{domain}.") and (is_wyoming or "wyoming" in str(attrs).lower()):
            engines.append(eid)
    return engines


async def create_pipeline(ws, stt_engine, tts_engine, language="ru"):
    """Create or update a voice assistant pipeline."""
    # List existing pipelines
    pipelines_result = await ws_call(ws, 300, "assist_pipeline/pipeline/list")

    existing = pipelines_result.get("pipelines", [])
    preferred = pipelines_result.get("preferred_pipeline")

    # Build pipeline data
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

    # Check if a Wyoming pipeline already exists
    pipeline_id = None
    for p in existing:
        if (p.get("stt_engine") == stt_engine and p.get("tts_engine") == tts_engine):
            pipeline_id = p["id"]
            print(f"  [OK] Pipeline already exists: {p.get('name')}")
            break

    if pipeline_id is None:
        # Create new pipeline
        pipeline_data["id"] = None  # Will be auto-generated
        result = await ws_call(ws, 301, "assist_pipeline/pipeline/create", **pipeline_data)
        pipeline_id = result.get("id")
        print(f"  [OK] Pipeline created with id={pipeline_id}")
    else:
        # Update existing
        result = await ws_call(ws, 301, "assist_pipeline/pipeline/update",
                               pipeline_id=pipeline_id, **pipeline_data)
        print(f"  [OK] Pipeline updated: {pipeline_id}")

    # Set as preferred
    if preferred != pipeline_id:
        await ws_call(ws, 302, "assist_pipeline/pipeline/set_preferred",
                      pipeline_id=pipeline_id)
        print(f"  [OK] Pipeline set as preferred")

    return pipeline_id


async def main():
    ha_token = os.environ.get("HA_API_TOKEN", "")
    ha_host = DEFAULT_HA_HOST
    ha_port = DEFAULT_HA_PORT

    for arg in sys.argv[1:]:
        if arg.startswith("--ha-host="):
            ha_host = arg.split("=", 1)[1]
        elif arg.startswith("--ha-port="):
            ha_port = int(arg.split("=", 1)[1])
        elif arg.startswith("--ha-token="):
            ha_token = arg.split("=", 1)[1]

    if not ha_token:
        print("ERROR: HA_API_TOKEN not set (use --ha-token=TOKEN)")
        sys.exit(1)

    try:
        import websockets
    except ImportError:
        print("ERROR: websockets library not installed")
        sys.exit(1)

    print(f"Connecting to Home Assistant at {ha_host}:{ha_port}...")
    ws = await ha_connect(ha_host, ha_port, ha_token)
    print("  [OK] Authenticated")

    # Step 1: Add Wyoming STT + TTS
    print("\n--- Adding Wyoming integrations ---")
    stt_ok = await add_wyoming_service(ws, ha_host, WHISPER_PORT, "whisper")
    tts_ok = await add_wyoming_service(ws, ha_host, PIPER_PORT, "piper")

    if not stt_ok or not tts_ok:
        await ws.close()
        print("\n✗ Wyoming integration failed — cannot create pipeline without STT/TTS engines")
        print("  Fall back to manual setup: HA → Settings → Devices & Services → Add Integration → Wyoming Protocol")
        return 1

    # Reconnect to get fresh state (newly added Wyoming entities)
    await ws.close()
    await asyncio.sleep(2)
    ws = await ha_connect(ha_host, ha_port, ha_token)

    # Step 2: Find Wyoming engine IDs
    print("\n--- Discovering STT/TTS engines ---")
    stt_engines = await find_wyoming_engine(ws, "stt")
    tts_engines = await find_wyoming_engine(ws, "tts")

    if not stt_engines:
        print("  [WARN] No Wyoming STT engine found in state list")
        # Fallback: list all STT
        stt_engines = [s["entity_id"] for s in (await ws_call(ws, 210, "get_states"))
                       if s["entity_id"].startswith("stt.")]
        print(f"  Available STT engines: {stt_engines}")

    if not tts_engines:
        print("  [WARN] No Wyoming TTS engine found in state list")
        tts_engines = [s["entity_id"] for s in (await ws_call(ws, 211, "get_states"))
                       if s["entity_id"].startswith("tts.")]
        print(f"  Available TTS engines: {tts_engines}")

    if not stt_engines or not tts_engines:
        await ws.close()
        print("\n⚠ Wyoming services added but STT/TTS engines not found in entity list.")
        print("  Wait 10 seconds and try again, or create the pipeline manually in UI:")
        print("  HA → Settings → Voice assistants → Add assistant")
        print("  STT: faster-whisper | TTS: Piper")
        return 1

    stt_engine = stt_engines[0]
    tts_engine = tts_engines[0]
    print(f"  STT: {stt_engine}")
    print(f"  TTS: {tts_engine}")

    # Step 3: Create pipeline
    print("\n--- Creating voice pipeline ---")
    try:
        pipeline_id = await create_pipeline(ws, stt_engine, tts_engine)
    except RuntimeError as e:
        await ws.close()
        print(f"\n⚠ Pipeline creation failed: {e}")
        print("  Create manually: HA → Settings → Voice assistants → Add assistant")
        print(f"  STT: {stt_engine} | TTS: {tts_engine}")
        return 1

    await ws.close()

    print("\n" + "=" * 50)
    print("✓ All done! Wyoming STT + TTS configured, pipeline created and set as preferred.")
    print(f"  Pipeline ID: {pipeline_id}")
    print(f"  STT: {stt_engine}  |  TTS: {tts_engine}")
    print("=" * 50)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
