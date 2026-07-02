---
name: docker-manage
description: Manage Docker containers, check logs, restart services, and troubleshoot containerized applications.
license: MIT
compatibility: opencode
metadata:
  audience: developers
  requires: docker-socket
---

## What I do
- List running containers and their status
- View container logs with filtering
- Start, stop, restart containers and services
- Check container health status
- Inspect Docker networks and volumes
- Troubleshoot deployment issues
- Run commands inside containers

## When to use me
Use this skill when you need to:
- Check application logs for errors
- Restart a service after code changes
- Verify container health after deployment
- Debug networking issues between containers
- Inspect mounted volumes and data persistence
- Check resource usage (CPU, memory)

## Commands reference
```bash
# List all running containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# View logs (last 100 lines, with timestamps)
docker logs --tail 100 --timestamps <container-name> 2>&1

# View logs since last restart
docker logs --since 10m <container-name> 2>&1

# Check container health
docker inspect --format='{{.State.Health.Status}}' <container-name>

# Restart a service
docker compose restart <service-name>

# Rebuild and restart
docker compose up -d --build <service-name>

# Check resource usage
docker stats --no-stream

# Run command in container
docker exec <container-name> <command>

# Follow logs in real-time
docker logs -f --tail 50 <container-name>

# Check all container statuses
docker compose ps
```

## Workflow
1. Run `docker ps` to see what's running
2. For each relevant container, check `docker logs --tail 100`
3. Look for: errors, exceptions, stack traces, OOM, connection refused, timeouts, segfaults
4. If errors found, report with timestamps and container name
5. If restarting, verify container becomes healthy again
6. After code changes, rebuild and check logs again

## Common issues
- **Container restarting**: Check logs for crash reason, verify volumes
- **Connection refused**: Check port mappings and network config
- **OOM**: Check memory limits in docker-compose.yml
- **Health check failing**: Check the healthcheck command output
