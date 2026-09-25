# Sekiro combat: the north star

This is the reference the combat code is tuned against. Each rule lists what Sekiro does, where
the information comes from, and how Dankiro implements it. Frame counts are at 60 fps
(1 frame = 16.7 ms). Timing values live in `scripts/combat/combat.gd`, and per-attack timings
live in `tools/build_animations.py`.

The automated checks in `tests/` (see the README) verify the rules marked **[tested]**.

## 1. Deflect vs block

| Rule (Sekiro) | Dankiro |
| --- | --- |
| Pressing guard opens a **12-frame (0.200 s) deflect window**. A blade that lands inside it is deflected. | `DEFLECT_WINDOW = 0.200`. Blade contact time is measured sub-tick with a swept test, and the press is stamped with sub-tick time. **[tested]** |
| **Spam penalty.** Pressing guard again soon after *releasing* it shrinks the next window, and each further quick press shrinks it more: "to as little as 4 frames, even 0 frames if you spam it too fast" (datamined, Fextralife). | Windows 12 → 8 → 6 → 4 → 0 frames: the fifth quick press in a row gets no window. A press counts as "quick" if it comes within 30 frames (0.5 s) of the last release. **[tested]** |
| The penalty clears after **30 frames** without a quick press, and **immediately after a successful deflect**, so deflecting a fast flurry in rhythm works. | Same. **[tested]** |
| Holding guard and releasing it just before pressing again also builds the penalty. | Same, because the penalty keys off the release. |
| **Holding guard** when a blade lands outside the window **blocks**: no vitality damage, a large hit to *your* posture, and a dull, quiet clank with a small spark. | Block when the guard pose is up (held, or still settling after a tap). **[tested]** |
| A full posture bar from blocking causes a **guard break**: you stagger and can be hit. | `_guard_break()` |
| Getting hit by a **light** blow staggers Wolf only briefly, so you can raise your guard and block (or deflect) the rest of a string. Heavy blows (perilous attacks, big finishers) knock you down. | A light blow (up to 20 damage, or a shuriken) keeps your guard down for 0.12 s (`HIT_STUN_LIGHT`), a heavier one for 0.22 s (`HIT_STUN`). A held guard comes back up by itself after that, and a press during the stagger is kept, so after missing one deflect of the whirl, the jabs or a shuriken volley, holding guard blocks the rest. **[tested]** |
| A **deflect** negates the damage, adds a *small* amount of your posture, and **can never break your posture**. | `add_posture(x, false)` clamps below max. **[tested]** |
| A deflect deals **large posture damage to the attacker**. Deflecting a combo's last hit staggers them briefly, giving you an opening. | `boss_posture` per hit, a ×1.35 bonus on a combo's final hit, and a `b_recoil` opening. |
| Deflecting several hits in quick succession deals more posture damage. | Chain bonus: +12% per consecutive deflect within 1.2 s, up to +36%. |
| Deflect feedback: a **huge spray of orange sparks** and a **loud, high-pitched CLANG**, instantly distinguishable from a block. | Layered streak sparks, star flash, light pulse, a bright "ting", ~75 ms hit-stop, shake and rumble. Blocks get a small dull spark and a quiet low clank. |
| Attacks from behind can't be guarded. | `GUARD_HALF_ANGLE = 110°` |

## 2. Perilous attacks (危)

A red kanji flashes with a warning sound. Sekiro has three kinds; this boss uses two.

| Kind | Sekiro | Dankiro |
| --- | --- | --- |
| **Thrust** | Can be deflected but not blocked. Its counter is the **Mikiri Counter**. It tracks you and has long reach, so stepping back just gets you stabbed as the step ends. | Blocking a perilous thrust fails and you get hit. He closes in during the wind-up, tracks you hard through the release, and the lunge stretches (up to 2×) if you backed off. A backstep, two backsteps, a backstep into a sprint, or an early side step all get stabbed, from 2.4 to 4.4 m. **[tested]** |
| **Sweep** | Can't be blocked or deflected, and dodge i-frames don't help. **Jump** over it, then press **jump again** while above or in front of him to **kick off his head** for major posture damage, with a bonus against sweeps. | Same. The kick deals ×1.6 posture during a sweep. The sweep is low (shin height) and ~2.5 m long. He chases you through the coil at up to sprint speed, and the blade only crosses in front of him once he has closed in. Stepping back or aside, two backsteps, walking away or sprinting away as the kanji shows all get caught, from 1.5 to 3.4 m: it forces the jump. **[tested]** |
| Grab | Can't be blocked. Dodge it. | Not used by this boss. |

### Projectiles

In Sekiro, thrown weapons such as shuriken and kunai are deflected or blocked like blades, and
deflecting them doesn't damage the thrower's posture. Dankiro's shuriken volleys work the
same way: every throw can be deflected (sparks, clang) or blocked, and hits if ignored.
**[tested]**

### Mikiri Counter

- **Input: dodge with no direction held.** A neutral dodge is a short *forward* step toward the
  enemy you face. Players consistently report that holding forward while pressing dodge tends
  to give an ordinary dodge rather than the counter, and that side or back dodges never
  counter. Dankiro follows that: only a neutral step counters. Holding forward gives a plain
  forward step, which the thrust runs through.
- **Timing: after the thrust is released.** The thrust can only be countered once the spear
  starts going forward. Dodging when the kanji first appears, or during the wind-up, is too
  early. Once it is moving, the window is generous: a thrust that lands while you're still in
  the step is countered.
- You stomp the blade into the ground, dealing heavy posture damage, and the enemy is left
  briefly open.
- Dankiro: the thrust has a visible pull-back and hold, then the release. A neutral step
  started from 0.1 s before the release onward counters it, as long as the thrust lands during
  the step. Stepping during the pull-back gets you hit, and so does a step with forward held,
  because a forward step's i-frames don't cover thrusts (see Dodging). **[tested]**

### Dodging

- Wolf's step is a **short, quick step with few i-frames** compared with a Souls roll. The base
  game's values (from a mod that documents them): **0.2 s** for side and back steps and
  **0.3 s** for forward steps, but a forward step's i-frames don't cover thrusts, and no
  step's i-frames cover sweeps. Dark Souls rolls get 0.3 to 0.43 s.
- Enemies track, and thrusts track hard. Players report that stepping back from a thrust just
  gets you stabbed as the step ends. A step repositions you (behind an enemy, out of a grab),
  but it doesn't carry you out of a committed attack's reach.
- Dankiro: steps travel **1.5 m** (back and side) and **1.1 m** (the neutral forward step), with
  Sekiro's i-frames (0.02 to 0.22 s, and 0.02 to 0.32 s forward). A strike dodged with
  i-frames isn't used up: if the blade is still on you when they end, it lands. During a
  wind-up he closes in, matching how fast you back off, so stepping, walking or sprinting away
  from the perilous thrust or sweep gets you hit. A side step timed right as the thrust
  arrives can still slip it, which Sekiro's side-step i-frames allow too. **[tested]**

## 3. Your attacks

| Rule (Sekiro) | Dankiro |
| --- | --- |
| Wolf's slashes are quick but committed. **You can't guard in the middle of a swing**; the guard comes up once the swing is done. | Each attack has *guard-cancel windows*: the very start of the wind-up (before the swing commits) and the recovery after the blade has passed. A guard press during the committed part is queued and comes up (with its deflect window) as soon as the recovery opens. **[tested]** |
| Attack rhythm: roughly two slashes a second in a string, and every slash costs a moment of commitment. | The first hit lands ~0.26 s after the press, and the next slash can start ~0.46 s after the previous one. The string is 3 slashes, and the last one is a heavier overhead. |
| Enemies block most of your attacks from neutral, and **keep attacking into their guard and they deflect you**, which knocks your sword away and leaves you open to a counter. | The boss guards and, after 2 to 4 blocked hits (1 to 3 in phase 2), parries and counters, and often keeps pressing after the counter. Being parried costs you posture and a longer recovery than his. |
| Deflecting a boss's combo opens him up for a hit or two, not for a stun-lock: bosses deflect your next swing, jump away, or counter through your string. | He reels from your first two hits after a stagger (one or two in phase two); the next one he parries, hops back from (his backstep has i-frames) into a thrust or leap, or takes and answers with a fast cut or a sweep. After reeling he often backs off or throws shuriken, and he avoids reopening with the attack you just punished. **[tested]** (`punish`, `loop`) |
| Hitting a guard doesn't damage it much. Posture damage mainly comes from deflects. | Blocked hits deal a small amount of posture. Most of his posture damage comes from deflects, mikiris and kicks. |

## 4. Posture

- Posture regenerates when you aren't being pressured, and regenerates **faster while holding
  guard**.
- **Lower vitality means slower posture regeneration** for both fighters, so damaging him with
  hits makes the posture war winnable.
- A full posture bar means a posture break: they drop, and you can **deathblow**.
- Bosses have several lives (Sekiro's deathblow marks). Sojin has three, one per phase.

## 5. Readability (why the fight is fair)

- Every attack has a clear wind-up pose and a sound cue *before* the active frames, and every
  opener gives at least 0.45 s of warning. Tells happen where you can see them: above or beside
  your character from the lock-on camera, which sits a little high and to the right. **[tested]**
- A blow lands when the blade actually reaches you, never the instant a hit window opens with
  the blade already touching you, so the deflect timing matches what you see. **[tested]**
- Hit windows are tested against the **whole weapon**. For the twin-blade staff that includes
  the shaft, so a strike never passes through you when you stand close.
- The deflect sound and sparks are big and bright, and blocks are dull by comparison, so you
  can hear your timing without looking.

## Sources

- Fextralife Sekiro wiki: [Deflection](https://sekiroshadowsdietwice.wiki.fextralife.com/Deflection)
  (12-frame window, spam penalty down to 4/0 frames, 30-frame reset, reset on deflect),
  [Mikiri Counter](https://sekiroshadowsdietwice.wiki.fextralife.com/Mikiri_Counter),
  [Perilous Attacks](https://sekiroshadowsdietwice.wiki.fextralife.com/Perilous_Attacks),
  [Posture](https://sekiroshadowsdietwice.wiki.fextralife.com/Posture)
- Steam community threads on
  [how the Mikiri Counter works](https://steamcommunity.com/app/814380/discussions/0/598531619385683737/)
  (neutral dodge = forward, wait for the thrust),
  [Mikiri Counter and timing](https://steamcommunity.com/app/814380/discussions/0/1850323802579482370/)
  (holding forward doesn't work, just press dodge; the window spans the step),
  [Mikiri dodge feels off](https://steamcommunity.com/app/814380/discussions/0/3592212630603805295/)
  (it only works once the thrust starts going forward) and
  [when to use the jump kick](https://steamcommunity.com/app/814380/discussions/0/1753520068682799746/)
- Dodge i-frames: the [Easier I-frames](https://www.nexusmods.com/sekiro/mods/417) mod
  (Nexus Mods), whose description lists the base game's values (forward step 0.3 s, not
  against thrusts or sweeps; side and back steps 0.2 s, not against sweeps), and PC Gamer,
  [*Sekiro plays almost exactly like Bloodborne with this rad combat mod*](https://www.pcgamer.com/sekiro-plays-almost-exactly-like-bloodborne-with-this-rad-combat-mod/)
  (the dash has only six i-frames)
- Steam community threads on dodging thrusts
  ([1](https://steamcommunity.com/app/814380/discussions/0/3570700856117009777),
  [2](https://steamcommunity.com/app/814380/discussions/0/1681441347867887898)): thrusts track
  too well to dodge away from
- Logan Taylor, [*Song of Sword and Fist: Sifu, Sekiro, and the Anatomy of a Perfect Parry*](https://medium.com/@gatherer286/song-of-sword-and-fist-sifu-sekiro-and-the-anatomy-of-a-perfect-parry-2f9c4c26867a)
  (deflect vs block audio and visual feedback)
