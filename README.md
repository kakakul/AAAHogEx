# HogNet OpenTTD AI

## Overview
HogNet is a fork of AAAHogEx. The original AAAHogEx is designed to maximise profit — it builds routes between towns that earn money and may leave small or isolated towns unserved indefinitely. HogNet changes the core objective: the AI works toward a single large network that eventually connects every town on the map, no matter how small or unprofitable.

## Pax and Mail Network Building
**Hub and Spoke**
The AI identifies the largest towns as major hubs to connect with high throughput connections. Smaller towns around each hub are then connected to the hubs. In this way, smaller towns can get connected to the larger network while still being profitable.

**No isolated route clusters**
In AAAHogEx, the AI may build profitable routes in completely separate parts of the map, resulting in disconnected islands of service. HogNet rejects any passenger or mail route that would form an isolated island — at least one endpoint of a new route must have a connection to the existing network. The whole map converges toward one unified transport system.

**Feeder bus and truck routes within towns**
When the AI builds a second station inside a town that already has a station, it now creates a short feeder service connecting the two stops within the town. This allows cargo and passengers to move between stations in the same town before being forwarded on longer-distance routes.

## Freight Cargo Handling
**Freight industries are connected into growing rail networks**
HogNet can build freight routes as part of its wider network strategy. It starts with a strong rail connection between a producing industry and an accepting industry, then expands from that line by adding new branches to nearby compatible producers. Instead of creating many isolated point-to-point freight lines, freight service grows outward from shared rail infrastructure, including a shared main line.

**Road feeders collect nearby cargo**
If smaller or nearby industries can provide cargo accepted by the active freight destination, HogNet can add road feeder routes into the freight rail station. These feeders help pull more cargo into the rail network without requiring every industry to get its own long-distance railway immediately.

## Other Changes
**Vehicle Buy/Sell Logic**
Vehicle buy/selling logic had to be refactored to take into account transiting passengers from other nodes in the network.


*Disclaimer: Portions of this codebase were generated or assisted by artificial intelligence tools (specifically Claude and GPT Codex).*