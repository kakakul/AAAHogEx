# HogNet OpenTTD AI

## Overview
HogNet is a fork of AAAHogEx. The original AAAHogEx is designed to maximise profit — it builds routes between towns that earn money and may leave small or isolated towns unserved indefinitely. HogNet changes the core objective: the AI works toward a single large network that eventually connects every town on the map, no matter how small or unprofitable.

## Network Building
**All towns get connected**
A new routine runs continuously in the background. It identifies every town that has no passenger service and methodically works to connect it to the existing network. It tries profitable options first (rail, air) and falls back to a road bus route if needed. No town is left behind.

**No isolated route clusters**
In AAAHogEx, the AI may build profitable routes in completely separate parts of the map, resulting in disconnected islands of service. HogNet rejects any passenger or mail route that would form an isolated island — both endpoints of a new route must have at least one connection to the existing network. The whole map converges toward one unified transport system.

## Freight Cargo Handling
**Freight industries are connected into growing rail networks**
HogNet can build freight routes as part of its wider network strategy. It starts with a strong rail connection between a producing industry and an accepting industry, then expands from that line by adding new branches to nearby compatible producers. Instead of creating many isolated point-to-point freight lines, freight service grows outward from shared rail infrastructure.

**Freight routes reuse junctions and shared main lines**
When HogNet builds a freight railway, it looks for places where future branch lines can safely join the route. Later freight sources can connect through those junctions and use the existing main line to reach the destination industry. This keeps freight expansion organized and makes the network feel like a connected system rather than a collection of separate tracks.

**Road feeders collect nearby cargo**
If smaller or nearby industries can provide cargo accepted by the active freight destination, HogNet can add road feeder routes into the freight rail station. These feeders help pull more cargo into the rail network without requiring every industry to get its own long-distance railway immediately.

## Intra-Town Feeder Routes
**Feeder bus and truck routes within towns**
When the AI builds a second station inside a town that already has a station, it now creates a short feeder service connecting the two stops within the town. This allows cargo and passengers to move between stations in the same town before being forwarded on longer-distance routes.

**Both passengers and mail are always served**
Each feeder connection provides service for both cargo types simultaneously. A bus for passengers and a truck for mail are both deployed on the route. Both feeder stops always have a bus stop and a truck stop physically attached, so neither cargo type is stranded.

**Feeder vehicles are protected from removal**
Feeder/support vehicles are marked as infrastructure and are not removed on profitability grounds, because they exist to feed the wider network rather than to turn a direct profit.

