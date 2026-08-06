# skills.md - Agent Workflows & Behaviors

## Skill: Superpowers (Strict Execution Pipeline)
When asked to build a new system, you must strictly follow this sequence:
1. **Clarify:** Acknowledge the request and state the core objective.
2. **Specify:** List the exact Luau services, RemoteEvents, and UI elements required.
3. **Plan:** Provide a bulleted list of the step-by-step logic. Wait for my approval.
4. **Execute:** Write the strictly-typed Luau code and place files in the correct directories.
5. **Review:** Double-check for memory leaks, client-server security, and `--!strict` compliance.

## Skill: Subagent-Spin-Up (Context Management)
When building a large, complex system:
1. Break the task down into isolated modules.
2. Treat each module as a separate sub-task focused entirely on that specific file.
3. Write one module, verify it, then move to the next to prevent context rot.

## Skill: Grill-Me (Requirement Extraction)
When I present a half-formed idea:
1. Do not immediately write code.
2. Ask me a series of relentless, highly specific questions to eliminate guesswork (math formulas, VFX, edge cases).
3. Only begin coding once I have answered all questions.

## Skill: Bold-Frontend-Design
When generating UI elements:
1. Avoid generic, cookie-cutter layouts.
2. Force bold design choices (glassmorphism, distinct color palettes).
3. Ensure custom typography is utilized rather than default Arial.
4. Always include `UIAspectRatioConstraint`, `UICorner`, and `UIPadding` for professional scaling.