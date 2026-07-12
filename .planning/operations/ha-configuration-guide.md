# Home Assistant Configuration Guide for Docker Deployments

> **Audience**: Operators of the home-dev-assistant stack. This guide ensures Home Assistant works reliably end-to-end — not just scripts, but all subsystems.

---

## Architecture Overview

```
Host: ./ha_config/              Container: /config/
├── configuration.yaml  ←──→   /config/configuration.yaml  (main config)
├── automations.yaml    ←──→   /config/automations.yaml    (included via !include)
├── scripts.yaml        ←──→   /config/scripts.yaml        (included via !include)
└── scenes.yaml         ←──→   /config/scenes.yaml         (included via !include)
```

The Docker volume bind `- ./ha_config:/config` means **any file you place in `./ha_config/` appears at `/config/` inside the container.** The Home Assistant runtime only reads `/config/configuration.yaml` at startup and follows `!include` directives from there.

---

## Mandatory `!include` Checklist

Every subsystem split into a separate file **must** have an `!include` directive in `configuration.yaml`. Without it, the file exists on disk but Home Assistant ignores it completely.

| Subsystem | Directive | File | UX symptom if missing |
|-----------|-----------|------|-----------------------|
| Automations | `automation: !include automations.yaml` | automations.yaml | «Создайте свою первую автоматизацию» |
| **Scripts** | `script: !include scripts.yaml` | scripts.yaml | «Создайте свой первый скрипт» |
| Scenes | `scene: !include scenes.yaml` | scenes.yaml | «Создайте свою первую сцену» |
| Templates | `template: !include templates.yaml` | templates.yaml | Template entities not registered |
| Custom sensors | `sensor: !include sensors.yaml` | sensors.yaml | Sensors not appearing |
| Lights/switches | `light: !include devices/lights.yaml` | devices/lights.yaml | Devices not appearing |
| Input booleans | `input_boolean: !include input_booleans.yaml` | input_booleans.yaml | Helpers not registered |

**Minimal working `configuration.yaml` skeleton:**

```yaml
default_config:

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
```

---

## YAML Rules for Home Assistant

### 1. Entity IDs must be strings

Home Assistant uses YAML keys as unique entity identifiers. Numeric keys are parsed as integers by YAML, which **breaks** internal entity resolution.

```yaml
# WRONG — parsed as integer
1720584135122:
  alias: My script

# CORRECT — parsed as string
'1720584135122':
  alias: My script
```

### 2. Never nest manually when using the UI

The browser-based YAML editor **wraps** your input with the entity ID key automatically. When pasting code, start from the content level (alias, sequence, etc.) — never include the outer key.

```yaml
# WRONG in browser YAML editor (causes double-nesting error)
say_on_phone:
  alias: Say text on phone
  sequence: ...

# CORRECT in browser YAML editor (start one level in)
alias: Say text on phone
sequence: ...
```

### 3. English metadata, localized later via UI

When writing YAML files from the terminal (console), use **English** for all metadata fields (alias, description). Russian/Cyrillic text in terminal-written files is vulnerable to:
- Locale mismatch between SSH session and container
- UTF-8 encoding corruption during `cat`/`tee` pipe
- Garbled output (`M-PM-^^M-PM-7...`) that HA rejects

**After** the script appears in the browser dashboard, rename/describe it in Russian through the UI — this uses HA's internal API and preserves encoding correctly.

---

## Docker Operations Reference

### Validate configuration before restart

Always run validation before restarting the container. An invalid config can cause a boot loop.

```bash
# From project root
docker compose exec homeassistant hass --script check_config -c /config
```

Expected output on success:
```
Testing configuration at /config
```

Or empty output = success.

### Safe restart procedure

```bash
# 1. Edit files in ./ha_config/
# 2. Validate
docker compose exec homeassistant hass --script check_config -c /config
# 3. Only restart if validation passes
docker compose restart homeassistant
```

### File permissions in Docker mounts

Files created from inside the container are owned by `root`. The host user can't modify them. Files created via `sudo` on the host are also owned by root. Both scenarios break the browser YAML editor.

```bash
# After any file operation that changes ownership:
sudo chown -R $USER:$USER ./ha_config/
sudo chmod -R 755 ./ha_config/
```

### Bash quoting rules for YAML directives

The YAML `!include` tag contains `!` which triggers Bash history expansion in double quotes:

```bash
# WRONG — Bash tries to expand !include
echo -e "\nscript: !include scripts.yaml" >> configuration.yaml

# CORRECT — single quotes disable history expansion
echo -e '\nscript: !include scripts.yaml' >> configuration.yaml
```

---

## File Writing Patterns

### Writing to Docker-owned files from host

```bash
# Pattern: sudo tee — bypasses permission denied for root-owned files
sudo tee ./ha_config/scripts.yaml << 'EOF'
'1720584135122':
  alias: My script
  ...
EOF
# Then restore ownership
sudo chown -R $USER:$USER ./ha_config/
```

### Checking what config HA actually sees

```bash
# View HA's perspective of the config
docker compose exec homeassistant cat /config/configuration.yaml
docker compose exec homeassistant cat /config/scripts.yaml
```

---

## Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| «Создайте свой первый скрипт» despite scripts.yaml existing | Missing `!include` in configuration.yaml | Add `script: !include scripts.yaml` |
| Script shows but won't run | Wrong `notify.mobile_app_*` service name | Check HA → Developer Tools → Services for actual service name |
| Save button greyed out in YAML editor | File owned by root | `sudo chown -R $USER:$USER ./ha_config/` |
| Container restarts in a loop | Invalid YAML syntax | Validate with `--script check_config` before restart |
| Cyrillic text shows as garbled | Terminal encoding mismatch | Write in English; localize via browser UI |
| `!include: event not found` in bash | `!` triggers history expansion | Use single quotes: `'script: !include scripts.yaml'` |
| Webhook from n8n fails to reach HA | Wrong token or URL | Verify token in HA profile; check HA network mode (`host`) |

---

## Configuration for All Subsystems (Beyond Scripts)

To ensure **every** subsystem works, verify the following are present:

### 1. REST Commands (n8n integration)

Already present in configuration.yaml:
```yaml
rest_command:
  n8n_voice_task:
    url: "http://127.0.0.1:5678/webhook/voice-task"
    method: POST
    headers:
      content-type: "application/json"
    payload: '{"prompt":"{{ prompt }}"}'
```

This requires `rest_command:` integration enabled (included in `default_config:`).

### 2. Mobile App Integration

```yaml
mobile_app:
```
This is required for `notify.mobile_app_*` services. Must be in configuration.yaml (included in `default_config:`).

#### Finding Your Device Notification Service

Each phone registered via HA Companion App gets a unique notification service. You must replace the placeholder in `scripts.yaml`:

1. Open HA → **Developer Tools** → **Services**
2. Type `notify.mobile_app` in the search field
3. Copy the full service name (e.g. `notify.mobile_app_infinix_x6731b`)
4. Replace `notify.mobile_app_YOUR_DEVICE` in `ha_config/scripts.yaml`

This is **the only device-specific value** in the entire HA config. Everything else is generic.

### 3. API Access

```yaml
api:
```
Required for REST API and webhook access (included in `default_config:`).

### 4. Voice Pipeline

```yaml
assist_pipeline:
```
Required for Wyoming Whisper + Piper STT/TTS (included in `default_config:`).

### 5. Conversation Integration

```yaml
conversation:
```
Required for Assist voice commands → automations (included in `default_config:`).

---

## Pre-Restart Checklist

Before any `docker compose restart homeassistant`:

- [ ] `grep -q "script: !include scripts.yaml" ./ha_config/configuration.yaml`
- [ ] `grep -q "automation: !include automations.yaml" ./ha_config/configuration.yaml`
- [ ] `docker compose exec homeassistant hass --script check_config -c /config` passes
- [ ] Files in `./ha_config/` are readable by container (disk exists, not corrupted)
- [ ] No YAML files contain raw unquoted `!include` that might trigger bash expansion
- [ ] Ownership: `sudo chown -R $USER:$USER ./ha_config/` (if recently edited via sudo)

---

## References

- [Home Assistant: Splitting Configuration](https://www.home-assistant.io/docs/configuration/splitting_configuration/)
- [Home Assistant: Troubleshooting Configuration](https://www.home-assistant.io/docs/configuration/troubleshooting/)
- [Home Assistant: Scripts](https://www.home-assistant.io/docs/scripts/)
- [Home Assistant: Docker Installation](https://www.home-assistant.io/installation/linux#docker-container)
