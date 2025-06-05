# k8s-apps

Kubernetes manifests for a homelab cluster deployed via GitOps with FluxCD.

## Applications

### Media & Automation
- **Arrs Suite**: Sonarr, Radarr, Readarr, Bazarr, Prowlarr + Transmission, Flaresolverr
- **Paperless**: Document management system

### Monitoring & Observability
- **Prometheus**: Metrics collection and alerting
- **Grafana**: Visualization and dashboards
- **Vector**: Log collection and processing
- **VictoriaMetrics**: Time series database and monitoring
- **VictoriaLogs**: Log aggregation and analysis

### Development & Automation
- **N8N**: Workflow automation platform
- **Atlantis**: Terraform automation and PR workflows
- **Ollama**: Local LLM inference server
- **NocoDB**: No-code database platform

### Productivity & Tools
- **Searxng**: Privacy-focused search engine
- **Excalidraw**: Collaborative whiteboarding tool
- **Umami**: Privacy-focused web analytics
- **Shlink**: URL shortener service
- **Atuin**: Shell history sync across devices
- **Home Assistant**: Home automation platform
- **Blog**: Personal blog application
- **Bots**: Custom bot applications

### Infrastructure & Storage
- **PostgreSQL**: Primary database server
- **Redis**: Caching and session storage
- **Cloudflared**: Secure tunnel to Cloudflare
- **Traefik**: Reverse proxy and load balancer
- **Vault**: Secret management and encryption

### Scheduled Tasks
- **CronJobs**: Automated tasks including meal notifications

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
