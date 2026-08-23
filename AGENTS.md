# Onyx agent notes

For any product, UX, UI, interaction, or perceived-performance work:

1. Read [`docs/PRODUCT_ISSUES.md`](docs/PRODUCT_ISSUES.md) before making changes.
2. Update the relevant issue while working: keep its status, decision, acceptance criteria, and verification current.
3. Record material product decisions in the decision log so later work does not silently reverse them.
4. Do not mark an issue **Done** until its acceptance criteria have been verified in a running build. If verification is pending, leave it **In progress**.
5. Add newly discovered product problems to the issue log instead of relying on chat history.

Keep updates concise and user-facing: describe the behavior people experience, not internal implementation names.

For any running preview or UI verification:

1. The only launchable development app is `dist-preview/Onyx Preview.app`.
2. Rebuild or relaunch it only with `scripts/run-preview.sh`.
3. Never launch Onyx with `swift run`, `.build/*/Onyx`, `dist/Onyx.app`, a test bundle, or a renamed/timestamped copy. Those create a visually inconsistent second app and can trigger another macOS permission cycle.
4. Subagents must not launch an app bundle. The primary agent owns the single preview lifecycle.
5. Keep the restrained near-black dark appearance as the visual baseline. Increase interaction geometry without making controls or panels look larger, brighter, or busier.
