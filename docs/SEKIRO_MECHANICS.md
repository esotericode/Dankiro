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
| **Spam penalty.** Pressing guard again soon after *releasing* it shrinks the next window, and each further quick press shrinks it more, down to 4 frames and then 0 if you mash. | Windows 12 → 8 → 6 → 4 → 0 frames. A press counts as "quick" if it comes within 30 frames (0.5 s) of the last release. **[tested]** |
| The penalty clears after **30 frames** without a quick press, and **immediately after a successful deflect**, so deflecting a fast flurry in rhythm works. | Same. **[tested]** |
| Holding guard and releasing it just before pressing again also builds the penalty. | Same, because the penalty keys off the release. |
| **Holding guard** when a blade lands outside the window **blocks**: no vitality damage, a large hit to *your* posture, and a dull, quiet clank with a small spark. | Block when the guard pose is up (held, or still settling after a tap). **[tested]** |
| A full posture bar from blocking causes a **guard break**: you stagger and can be hit. | `_guard_break()` |
| A **deflect** negates the damage, adds a *small* amount of your posture, and **can never break your posture**. | `add_posture(x, false)` clamps below max. **[tested]** |
| A deflect deals **large posture damage to the attacker**. Deflecting a combo's last hit staggers them briefly, giving you an opening. | `boss_posture` per hit, a ×1.35 bonus on a combo's final hit, and a `b_recoil` opening. |
| Deflecting several hits in quick succession deals more posture damage. | Chain bonus: +12% per consecutive deflect within 1.2 s, up to +36%. |
| Deflect feedback: a **huge spray of orange sparks** and a **loud, high-pitched CLANG**, instantly distinguishable from a block. | Layered streak sparks, star flash, light pulse, a bright "ting", ~75 ms hit-stop, shake and rumble. Blocks get a small dull spark and a quiet low clank. |
| Attacks from behind can't be guarded. | `GUARD_HALF_ANGLE = 110°` |

## 2. Perilous attacks (危)

A red kanji flashes with a warning sound. Sekiro has three kinds; this boss uses two.

| Kind | Sekiro | Dankiro |
| --- | --- | --- |
| **Thrust** | Can be deflected but not blocked. Its counter is the **Mikiri Counter**. | Blocking a perilous thrust fails and you get hit. **[tested]** |
| **Sweep** | Can't be blocked or deflected, and dodge i-frames don't help. **Jump** over it, then press **jump again** while above or in front of him to **kick off his head** for major posture damage, with a bonus against sweeps. | Same. The kick deals ×1.6 posture during a sweep. **[tested]** |
| Grab | Can't be blocked. Dodge it. | Not used by this boss. |

### Mikiri Counter

- **Input: dodge with no direction held, or held toward the enemy.** In Sekiro a neutral dodge
  is a *forward* step, which is why the neutral press is the reliable way to mikiri. Side and
  back dodges never mikiri.
- **Timing matters.** Dodging when the kanji first appears is too early: the counter only
  happens if the thrust arrives while the step is still in its mikiri frames. Community players
  describe it as "forgiving", so the window is generous but real.
- You stomp the blade into the ground, dealing heavy posture damage, and the enemy is left
  briefly open.
- Dankiro: a neutral dodge while locked on is a short forward step (~1.3 m, not a dash). If
  the perilous thrust reaches you within the step's first **0.33 s (20 frames)**, you mikiri.
  **[tested]**

## 3. Your attacks

| Rule (Sekiro) | Dankiro |
| --- | --- |
| Wolf's slashes are quick but committed. **You can't guard in the middle of a swing**; the guard comes up once the swing is done. | Each attack has *guard-cancel windows*: the very start of the wind-up (before the swing commits) and the recovery after the blade has passed. A guard press during the committed part is queued and comes up (with its deflect window) as soon as the recovery opens. **[tested]** |
| Attack rhythm: roughly two slashes a second in a string, and every slash costs a moment of commitment. | The first hit lands ~0.26 s after the press, and the next slash can start ~0.46 s after the previous one. The string is 3 slashes, and the last one is a heavier overhead. |
| Enemies block most of your attacks from neutral, and **keep attacking into their guard and they deflect you**, which knocks your sword away and leaves you open to a counter. | The boss guards and, after 2 to 4 blocked hits (1 to 3 in phase 2), parries and counters. Being parried costs you posture and a longer recovery than his. |
| Hitting a guard doesn't damage it much. Posture damage mainly comes from deflects. | Blocked hits deal a small amount of posture. Most of his posture damage comes from deflects, mikiris and kicks. |

## 4. Posture

- Posture regenerates when you aren't being pressured, and regenerates **faster while holding
  guard**.
- **Lower vitality means slower posture regeneration** for both fighters, so damaging him with
  hits makes the posture war winnable.
- A full posture bar means a posture break: they drop, and you can **deathblow**.

## 5. Readability (why the fight is fair)

- Every attack has a clear wind-up pose and a sound cue *before* the active frames.
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
  (neutral dodge = forward, wait for the thrust) and
  [when to use the jump kick](https://steamcommunity.com/app/814380/discussions/0/1753520068682799746/)
- Logan Taylor, [*Song of Sword and Fist: Sifu, Sekiro, and the Anatomy of a Perfect Parry*](https://medium.com/@gatherer286/song-of-sword-and-fist-sifu-sekiro-and-the-anatomy-of-a-perfect-parry-2f9c4c26867a)
  (deflect vs block audio and visual feedback)
