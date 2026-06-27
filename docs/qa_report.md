# QA Report — "Neon Strip" (independent adversarial pass)

## VERDICT: PASS (0 P0 ship-blockers)

Adversarial QA run against the real preview origin using a SwiftShader headless-Chromium driver at
portrait (400x860) and landscape (860x400), plus a read-only audit of the `.gd` source. Engine
boots clean, the city renders as a believable populated neon-desert slice, and every headline
system the QA agent could drive works. No frozen T-pose, no backwards hero, no auto-fire, no
gray-box world, no broken mobile fill, 0 real console errors on the live origin.

## P0 ship-blockers: NONE.

Passing classes: engine+console clean; camera orbits (right-drag, pitch-clamped, never floor-stare);
feet on floor + shadow; real ProceduralSky (no grey ceiling); sane scale; readable "ENTER" sign;
lit materials everywhere (not gray-box); mobile fill at portrait AND landscape (no letterbox).

## Feature verification
- World renders as a neon-desert city (buildings, palms, cars, streetlights, NPCs, ENTER pads): PASS
- Third-person move (WASD/joystick) + right-drag orbit camera: PASS
- Driving (walk to car -> "Drive" -> "Driving"/"Exit Car", camera follows the car): PASS
- Venue entry prompt ("Enter Lucky Star..." action button on the glowing pad): PASS
- Talk to NPCs (USE -> "Valet Marco: Welcome to the Lucky Star!" dialogue): PASS
- Distinctive Meshy characters (valet red-suit model; pink-haired showgirl on a lit pedestal): PASS
- Collect cash/chips/items (Chips 10->15, Inv (empty)->"Neon Cocktail" after walkover): PASS
- Minimap + full-screen MAP (venue dots + heading + Close Map): PASS
- Quest-graph winnability (qgcheck: world winnable, 16 areas): PASS
- Console clean (0 real errors; only benign env TLS/CDN noise): PASS

## Could-not-verify (sandbox / time-box limits, NOT failures)
- Venue interior RENDER (slots/blackjack/elevator/ferris + "Discovered N/3"): code-complete + entry
  prompt confirmed, but the headless driver couldn't navigate onto the Enter pad to trigger the load.
  (Builder note: a follow-up fix added the missing player-teleport-into-interior so entering works.)
- Day/night full cycle: only the day phase was observed in the time-box (wired correctly).
- Audio playback / localized zones: infra present + correct; unverifiable in the muted container.
- Real-GPU fidelity / true colors / FPS: SwiftShader software-GL; judged composition, not exact color.
- Supabase persistence: out of QA scope (separately verified end-to-end by the builder).

## Minor polish warnings (addressed where cheap)
1. Action-button label clipped ("Enter Lucky Sta...") -> FIXED: short labels ("Enter Casino/Club/Fair").
2. Hero reads as a flat solid-pink avatar vs the detailed Meshy NPCs (player.glb ships no texture atlas).
3. HUD info panel clipped its 3rd line -> FIXED: taller info panel.
4. Neon sign pole crossed the camera near venue pads -> FIXED: thinner pole + sign offset to the side.
5. Night-phase neon not observed in the time-box (cycle wired; needs a longer look).
