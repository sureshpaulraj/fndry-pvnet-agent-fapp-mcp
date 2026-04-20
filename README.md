# Hybrid Network AI Agent

A production-grade AI agent deployed on Azure with private networking, running on AI Foundry with gpt-4.1-mini. The agent executes client-side tool calls (Weather API via Azure Function + DateTime via MCP Server) within a fully private VNet, and is accessible via both a Jump VM (CLI) and Microsoft Teams (Bot Framework + Microsoft Agents SDK).

## Architecture Highlights

- **AI Foundry** agent with 6 function tools (client-executed)
- **Private VNet** (10.0.0.0/16) with 6 subnets, 9 Private Endpoints, 7 Private DNS Zones
- **Azure Function** (Flex Consumption, Python 3.11) with EasyAuth + Managed Identity
- **MCP Server** (Streamable HTTP) on internal Container Apps Environment
- **Agent Webapp** (aiohttp + Microsoft Agents SDK) on external Container Apps Environment for Teams/M365
- **Application Insights + Log Analytics** for full observability across all services
- **Terraform** — 10 modules, ~60+ resources, full state management

## Getting Started

Follow the **[Setup Guide](SETUP-GUIDE.md)** for a complete step-by-step walkthrough covering:

1. Prerequisites and Azure subscription requirements
2. App registrations (Bot Framework + Blueprint for Agents SDK)
3. Terraform infrastructure provisioning
4. Building and deploying the Weather Function, MCP Server, and Agent Webapp
5. AI Foundry agent creation and tool configuration
6. Teams integration via A365 CLI
7. Verifying Application Insights telemetry

## Additional Documentation

| Document | Description |
|----------|-------------|
| [SETUP-GUIDE.md](SETUP-GUIDE.md) | Step-by-step deployment walkthrough with prerequisites |
| [SKILL.md](SKILL.md) | Deep-dive technical reference — architecture, modules, lessons learned |
| [diagrams/architecture-diagrams.md](diagrams/architecture-diagrams.md) | Mermaid architecture diagrams (high-level, component, data flow, network) |

## Project Structure

```
├── agent-webapp/       # aiohttp app with Microsoft Agents SDK (Teams/M365 channel)
├── ai-agent/           # Jump VM agent script (foundry_agent.py)
├── azure-function-server/  # Weather Azure Function (Flex Consumption)
├── mcp-server/         # DateTime MCP Server (Streamable HTTP)
├── infra-terraform/    # Terraform IaC (10 modules)
├── diagrams/           # Architecture diagrams (Mermaid)
├── scripts/            # Deployment helper scripts
├── SETUP-GUIDE.md      # Guided setup walkthrough
└── SKILL.md            # Technical reference
```

## License

Internal / AI Guild project.
