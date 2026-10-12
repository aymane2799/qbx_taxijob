# qbx_taxijob
Taxi Job For Qbox

## Atlas fork

This is a fork of [Qbox-project/qbx_taxijob](https://github.com/Qbox-project/qbx_taxijob) at commit `f386f56`,
kept for the Atlas server. One change: **the server decides what an NPC ride pays.**

Upstream, the client sends the fare with `qb-taxi:server:NpcPay`, and the server pays whatever it is told up to
`maxFare`, to any taxi driver standing near any drop-off point. In this fork:

| Step | Upstream | Fork |
|---|---|---|
| Start a ride | The client picks pick-up and drop-off at random | Callback `qb-taxi:server:startRide`: the server picks both, computes the fare from the straight-line distance (`pricePerMile`, `startingPrice`, `maxFare` in `config/server.lua`), and remembers the ride |
| Pick-up | Client only | Callback `qb-taxi:server:pickUp`: the driver must be at that pick-up point, in an allowed cab |
| Payment | `NpcPay(amount)` from the client | `NpcPay()` takes no amount. Paid once, only for a ride that was picked up, only at that ride's drop-off, and only when the ride took at least `distance / maxAverageSpeed` seconds |
| Meter | Counts from the client's own price | Counts up to the server's fare; display only |

The fare uses the straight-line distance because the road distance is only known to the client, so fares are
somewhat lower than upstream's at the same price per mile. Rides between players are not paid by this resource,
upstream or here.

Rebase on a new upstream commit: `git fetch upstream && git rebase upstream/main`. The patch touches
`server/main.lua` (the `NpcPay` handler and the two callbacks above it), `config/server.lua`, six places in
`client/main.lua` marked by `serverRide` and the two callbacks, and one key in `locales/en.json`
(`error.ride_unavailable`; other languages fall back to English).
