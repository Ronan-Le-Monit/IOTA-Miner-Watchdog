# IOTA Watchdog

A small macOS menu-bar app that notices when your **IOTA Train at Home** miner stops, crashes,
freezes or quietly stops making progress, and restarts it for you.

Free and open source. If it saves you some mining time, there is a way to say thanks at the
bottom of this page.

> Not affiliated with, endorsed by, or supported by Macrocosmos. It works alongside their
> IOTA Train at Home app by reading the log files that app already writes.

---

## Why it exists

IOTA Train at Home does not restart its miner when the worker dies. On 4 September 2026 a miner
here hit a fatal error at 11:09, exited at 11:10, and the app sat idle until someone noticed and
pressed Start at 12:36. That is 86 minutes of nothing.

The watchdog notices within about a minute and restarts the app, which starts training again by
itself.

## What it watches

Every 30 seconds it reads the miner's log, checks whether the worker process is alive, and every
five minutes asks the public Macrocosmos API whether your activations are still climbing, which
run you are in, and how full every run is.

It restarts the miner when:

| Trigger | Condition |
|---|---|
| Crash or clean shutdown | A fatal error or a shutdown line, and the worker is gone |
| Worker vanished | No worker process for two consecutive checks |
| Frozen | The process is alive but has written nothing for 5 minutes |
| No progress | Nothing for 60 minutes, confirmed by the API not crediting activations |
| Sustained reset loop | 5+ resets spanning at least an hour, with the API crediting nothing |

The last two both require the public API to agree before anything happens. Log evidence alone is
never enough, because a miner can look idle in its log while the network is still crediting it.

Before every automatic restart a window appears with a 60 second countdown, the reason, and the
log line behind it. Cancel stops it and suspends automatic restarts until the miner runs again.

Restarts are capped at three per hour with at least ten minutes between them, so a miner that
cannot start is not thrashed.

## What it deliberately does not do

- **It does not restart a miner that is waiting for the network.** A miner that registers
  mid-epoch cannot train until the run's next full synchronisation, which is one to two hours
  away. Restarting there makes it worse: it re-registers and misses that sync too. The app reads
  the run's sync schedule and shows `Waiting for network sync (~HH:MM)` instead.
- **It does not restart when the whole run has stalled.** A run can stop syncing while your
  miner is perfectly healthy. Restarting cannot help, because the orchestrator puts you straight
  back into the same run — measured here as 3,269 identical answers over nine days, across 182
  re-registrations. On 19 September one run had gone 189 hours without syncing while seven of the
  other eight had synced within two hours; its 120 miners had a median of 3 activations against
  4,092 in a run of the same tier. The app compares your run's sync age against every other run
  and reports `Run has stalled` instead of restarting.
- **It does not restart during a network outage.** If the orchestrator is unreachable a restart
  cannot help, so it holds.
- **It does not undo a stop you made yourself.** If you press Stop Training, it stays stopped.
- **It does not restart a miner that is still trying to join a run.** When a batch of runs goes
  live, joining legitimately involves cycling through reset and registration, sometimes for
  twenty to sixty minutes, before getting in. That looks identical to a broken miner for the
  first hour, so the reset-loop rule needs a loop lasting longer than that *and* API
  confirmation. Thanks to Moonlit on the Macrocosmos Discord for pointing this out.
- **It ignores the noisy stuff.** NaN losses, stale requests, attestation retries, peer timeouts
  and high GPU memory warnings all look alarming in the log and are all normal.

## Keeping the Mac awake

System sleep is the most common cause of lost mining time. A Mac set to sleep after a few minutes
will freeze the miner, which then gets dropped from its run and needs several minutes to
re-register on wake. The app holds a power assertion while the miner runs, and warns you if the
system is configured to sleep almost immediately.

This cannot defeat a closed lid unless the Mac is in clamshell mode, nor a thermal sleep.

## Requirements

- macOS 26.5 or later
- IOTA Train at Home installed in `/Applications`
- **"Start training when the app launches" enabled** in the IOTA app's settings. The watchdog
  restarts the miner by quitting and relaunching that app, and relies on it starting training by
  itself. Without this it will tell you it cannot restart automatically.

## Install

Download the latest release, unzip it, and drag **IOTA Watchdog.app** to your Applications folder.

The app is signed and notarised by Apple, so it opens normally.

On first launch a window appears showing the status. **After that the app lives only in the menu
bar as a small cube.** There is no Dock icon and no window. If your menu bar is full, macOS may
hide the icon; open the app again from Applications to bring the window back.

## Using it

Open the menu bar icon. It shows the miner it is watching, whether the worker is running, how
fresh the log is, when the last activation was, and your rank and activation count from the API.

It also names the run you are in and how full it is, for example `120 / 120 (full)`. While the
miner is between runs the same line reads **Queueing for** and names the run the orchestrator has
put you down for, which it knows from your own log before the network lists you as a member.

There is no queue *position*. The orchestrator does not send one: across nine days of logs here,
none of 3,269 responses carried a position, place or queue size. The miner process advertises a
`register.queue_state` message on every startup but has never actually sent one. The app reads
that message and will show the position the moment one arrives, and writes the raw payload to its
log so the format can be supported properly. Until then it shows nothing rather than a guess.

Three switches:

- **Restart the miner automatically.** Off by default, on purpose. This app force-quits and
  relaunches another app, so turn it on knowingly and watch the first restart.
- **Keep the Mac awake while training.** On by default.
- **Start the watchdog at login.** Off by default. The app must be in `/Applications` for this.

Which miner it watches is worked out from the Bittensor wallet on your Mac. Only the public
address is read. If you run several wallets, type the hotkey prefix into the field yourself.

The first time it restarts the miner, macOS may ask for permission to control IOTA Train at Home.
Allow it. If you deny it the restart still works, using a less graceful quit.

## Where things live

| What | Path |
|---|---|
| Its own log | `~/Library/Logs/IOTA Watchdog/watchdog.log` |
| Settings | `~/Library/Application Support/IOTA Watchdog/settings.json` |
| Miner logs it reads | `~/Library/Logs/IOTA Train at Home/` |

The log records every state change with the evidence behind it, and says why it did *not* restart
when it decided against one. If something looks wrong, that file usually explains it.

## Known quirk in IOTA Train at Home

The Miner panel in IOTA Train at Home may show a completely different miner's ID, rank and
activations. It picks a training run to display and, when your miner is not in that run, falls
back to showing the first node in the list rather than reporting that it could not find you. The
figures in this watchdog come from looking your hotkey up across every active run, so where the
two disagree, this one is right. Nothing you can configure fixes the other app; it needs a fix
from Macrocosmos.

## Building it yourself

Open the project in Xcode and build the **IOTA Watchdog** scheme. There are no dependencies.

Keep **App Sandbox off** and **Hardened Runtime on**. The sandbox is not a setting that can be
turned on here: it blocks reading another app's logs, reading the wallet, and quitting or
launching another app, which is everything this does. A sandboxed build launches and then reports
a healthy miner on no evidence at all.

Tests: `xcodebuild -scheme "IOTA Watchdog" -destination 'platform=macOS' test`. Note the app is
the tests' host, so it launches during a test run; it detects XCTest and does not start watching,
which stops a test run from restarting your real miner.

## Support this project

This app is free and always will be. If it saves you some mining time and you would like to say
thanks:

- [Ko-fi](https://ko-fi.com/monit)
- [Buy Me a Coffee](https://buymeacoffee.com/le_monit)

Both links are also in the app's own menu, at the bottom.

## Licence

MIT. See [LICENSE](LICENSE).
