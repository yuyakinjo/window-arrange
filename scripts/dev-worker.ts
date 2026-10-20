import { registerInputs } from "./dev-support";

// Bun --watch follows imported files. Register Swift and resources as text, not JavaScript.
await registerInputs();

// Keep builds in the supervisor: --watch restarts do not await asynchronous signal cleanup.
console.log("inputs-changed");
setInterval(() => {}, 60_000);
