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

By default it restarts the miner only on direct evidence that something has stopped:

| Trigger | Condition |
|---|---|
| **Miner shut down** | The miner logs `🛑 Miner shutdown complete` |
| Fatal error | The miner logs a critical error; the watchdog waits up to 5 minutes for it to finish cleaning up and shut down |
| Worker vanished | No worker process for two consecutive checks |
| Frozen | The process is alive but has written nothing at all for 5 minutes |
| App quit | IOTA Train at Home is not running at all, so it is relaunched |

The shutdown line is the most important of these. The IOTA app never restarts a miner that has
shut down: on 8 October a Mac Mini here hit a fatal error, spent 2 min 41 s cleaning up, logged
`Miner shutdown complete`, and then sat idle for ten minutes until someone intervened. The
watchdog gives the process 60 seconds to exit after that line and then restarts regardless,
because the miner process can stay listed after training has ended. A shutdown is acted on even
straight after a start, and even when the run itself looks dead: a miner that has shut down is not
training either way.

A miner **waiting in the registration queue** is never restarted. While queued it does nothing
but poll its place, about once a minute, and the menu shows `Queued — position #38`. On
11 October an earlier version restarted a miner that had been queued for two hours, calling it
frozen, because it did not recognise any of the queue lines. "Frozen" now means the miner has
stopped writing anything, not that it has stopped writing lines the watchdog understands. If the
queue itself stops reporting for ten minutes, the normal rules apply again.

Before every automatic restart a window appears with a 60 second countdown, the reason, and the
log line behind it. Cancel stops it and suspends automatic restarts until the miner runs again.

Restarts are capped at three per hour with at least ten minutes between them, so a miner that
cannot start is not thrashed.

### Optional rules, off by default

Three more rules are available under **Optional rules** in the menu. They are off by default
because each depends on inference, and each has been wrong in practice. Between 2 and 4 October a
miner stuck in its `initializing` state was restarted about 73 times by the no-progress rule to no
effect; what fixed it was pressing **Recover** in the IOTA app. Switch them on if you want them.

| Rule | What it does when switched on |
|---|---|
| No progress | Restarts after 60 minutes without an activation, if the public API agrees nothing is being credited |
| Reset loop | Restarts a miner that has reset 5+ times over at least an hour, again only with the API agreeing |
| Hold for the run's state | Holds off restarting while the whole run has stalled or the miner is waiting for the next network sync |

About the hold: a miner that registers mid-epoch cannot train until the run's next full
synchronisation, one to two hours away, and restarting it makes it miss that sync too. And a run
can stop syncing altogether, in which case restarting cannot help, because the orchestrator puts
you straight back into the same run: measured here as 3,269 identical answers over nine days,
across 182 re-registrations. On 19 September one run had gone 189 hours without syncing while
seven of the other eight had synced within two hours; its 120 miners had a median of 3 activations
against 4,092 in a run of the same tier.

With the hold switched off, both conditions are still **shown** in the menu, as
`Waiting for network sync (~HH:MM)` and `Run has stalled`. They just no longer block a restart.

## What it deliberately does not do

- **It does not undo a stop you made yourself.** If you press Stop Training, it stays stopped,
  including while the miner is still winding down.
- **It does not restart during a network outage.** If the orchestrator is unreachable a restart
  cannot help, so the frozen rule, and any optional rule you have switched on, holds.
- **It does not restart a miner that is still trying to join a run**, when the reset-loop rule is
  on. Joining legitimately involves cycling through reset and registration, sometimes for twenty
  to sixty minutes, so the rule needs a loop lasting longer than that *and* API confirmation.
  Thanks to Moonlit on the Macrocosmos Discord for pointing this out.
- **It does not fix a miner stuck initializing.** A miner that is alive and busy but turns down
  every piece of work with `NACK (status=initializing)` is not cured by a restart. The cure seen
  so far is the **Recover** button in the IOTA app.
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

It also names the run you are in and how full it is, for example `120 / 120 (full)`. Just after
the orchestrator assigns a run, and before the network lists you as a member, the same line reads
**Queueing for** and names that run, which the watchdog reads from your own log.

While the miner is queueing for a place, the menu shows its **queue position** as the
orchestrator reports it. Expect it to jump around: on 11 October it went from #1029 to #341, then
between roughly #190 and #890 for an hour and a half, before settling at #38. A place can also
expire, in which case the miner joins again and the history notes it. The IOTA app itself cannot
show this yet; it answers the miner's attempts to pass the position on with
`No handler for register.queue_state`.

Three switches:

- **Restart the miner automatically.** Off by default, on purpose. This app force-quits and
  relaunches another app, so turn it on knowingly and watch the first restart.
- **Keep the Mac awake while training.** On by default.
- **Start the watchdog at login.** Off by default. The app must be in `/Applications` for this.

Below them, **Optional rules** holds the three rules described above, all off until you switch
them on.

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
