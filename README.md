# k8s-apps

Kubernetes manifests for a homelab cluster deployed via GitOps with FluxCD.

## Applications

### Media & Automation
- **Arrs Suite**: Sonarr, Radarr, Readarr, Bazarr, Prowlarr + Transmission, Flaresolverr
- **Paperless**: Document management system

### Monitoring & Observability
- **Prometheus**: Metrics collection and alerting
- **Grafana**: Visualization and dashboards
- **ELK Stack**: Elasticsearch, Kibana, Elastic Agent
- **Loki**: Log aggregation
- **Vector**: Log collection and processing
- **VictoriaMetrics**: Time series database
- **Uptime Kuma**: Service monitoring

### Development & Automation
- **N8N**: Workflow automation
- **Atlantis**: Terraform automation
- **Windmill**: Workflow engine
- **Ollama**: Local LLM inference

### Productivity & Tools
- **Linkding**: Bookmark manager
- **Searxng**: Privacy-focused search engine
- **Excalidraw**: Collaborative whiteboarding
- **Umami**: Privacy-focused analytics
- **Shlink**: URL shortener
- **Atuin**: Shell history sync
- **Home Assistant**: Home automation

### Infrastructure
- **MinIO**: S3-compatible object storage
- **PostgreSQL**: Primary database
- **Redis**: Caching and sessions
- **Cloudflared**: Secure tunnel to Cloudflare
- **Traefik**: Reverse proxy and load balancer
- **Infisical**: Secret management

## Setup

Bootstrap FluxCD to deploy all applications:

```bash
flux bootstrap github \
  --owner=mvaldes14 \
  --repository=k8s-apps \
  --branch=main \
  --path=fluxcd \
  --personal
```

## Structure

- `fluxcd/` - FluxCD Kustomizations and sources
- `*/` - Individual application manifests
- `base/` - Shared resources (StorageClass, etc.)
- `crds/` - Custom Resource Definitions

All applications are configured for automatic deployment and updates via GitOps.
