# Home Dock Design QA

- Reference: `codex-clipboard-1b326774-0534-47fd-b192-77b440fc6f63.png`
- Render: `/tmp/dock-preview-compact.png`
- Viewport: iPhone 17 Pro Max, iOS 26.5 Simulator
- Normal state: selected background fills the complete left slot; icon, label, dividers, outer capsule, and shadow match the reference hierarchy.
- Plan-ready state: calendar label remains visible; the centered CTA expands over reserved space without moving the side anchors.
- Fixed anchors: calendar, plan, and settings centers remain unchanged between states.
- Text: `日历` and `开始训练` render without clipping.
- Compactness revision: slot height reduced from 68pt to 56pt; fixed centers and 148pt CTA width remain unchanged.
- Remaining P3: simulator material and generated reference use slightly different shadow diffusion.

final result: passed
