# Bowerboard (blurt)

Bowerboard is a live, no-login participation tool: a host creates a "bower" (room) —
a word cloud, brainstorm board, sticky-note board, ranking task, multiple-choice
question, or multi-question poll/quiz — and shares a room code / QR so people can
join instantly from their phone and post, vote, or rank in real time.

## Audience and terminology

The product is used in two settings: **school classrooms** and **organizational
meetings/workshops**. Don't write user-facing copy (UI text, button labels, marketing
copy, error messages, onboarding text) using classroom-only language like "teacher" or
"student" — that framing narrows the product to education. Prefer neutral terms like
"host" / "organizer" and "participants" / "the room" in anything a user reads.

This is a naming convention for *user-facing text* only. The codebase's internal
function and variable names (`renderTeacherLive`, `renderStudentRoom`, `s.studentName`,
etc.) are historical and pervasive — don't do a mass rename as a side effect of an
unrelated task. If you're adding a substantial new feature from scratch, prefer neutral
internal names for it, but don't block on renaming existing code.

## Git / PR workflow

Whenever changes are committed and pushed to a branch, always open a pull request for
them — don't wait to be asked. This overrides any default elsewhere that says to only
create a PR on explicit request.

Never merge a pull request yourself. When a PR is ready to merge (CI green, no
unresolved conflicts or review comments), tell the user explicitly and give the exact
URL — e.g. "PR #9 is ready to merge: https://github.com/KAG111/blurt/pull/9" — and wait
for them to merge it themselves. Don't just mention that a PR exists or is "ready";
call out clearly that merging is the next step and it's on them to do it.

## Architecture

This is a **single static HTML file with no build step**: `index.html` (~6,400 lines)
contains all CSS (`<style>`, lines ~13–849) and all JS (`<script>`, lines ~854–6400)
inline. There's no `package.json`, no bundler, no npm scripts. Deployment is Cloudflare
Pages serving the repo directly from GitHub (see `bowerboard-manifest.xml`, which points
the PowerPoint add-in at `https://bowerboard.app/` — the add-in is just that URL in an
iframe, not a separate code path). The project previously deployed via Netlify; that
connection has been removed in favor of Cloudflare.

Other files in the repo:
- `logo.png`, `poll_preview.png`, `quiz_preview.png`, `sticky_preview.png` — static
  assets referenced by the landing page.
- `bowerboard-manifest.xml`, `bowerboard-powerpoint-instructions.txt`,
  `bowerboard-powerpoint-addin.zip` — PowerPoint add-in packaging. Rarely relevant.
- `netlify/functions/room.js` — **legacy/unused.** Implements room storage against an
  external JSON-storage API (extendsclass.com). Nothing in `index.html` calls it — the
  live app talks to Supabase directly (see below). Don't assume it's the active
  backend; if a task seems to require touching storage, look at `kvGet`/`kvSet` in
  `index.html` instead.

## Backend: Supabase

Storage is a single Supabase table `rooms` (keyed by `code`), accessed through two
thin wrapper functions:
- `kvGet(key)` / `kvSet(key, value)` (~line 1332, 1360) — `key` is a synthetic
  `'room:<code>:<property>'` string; the wrappers split it and read/write that column
  on the row for `code`. Properties in use: `config`, `words`, `posts`, `votes`,
  `responses`, `roster`.
- Realtime updates are polling-based via `setupRealtimeListener` (~line 1392), not
  raw Supabase subscriptions.
- Moderation ("Phone Remote" / split-screen mode) shadow-writes to a parallel room
  keyed `MOD-<code>` before merging into the main room — see `getTargetRoom`,
  `mergeShadowIntoMain`.

The Supabase client library loads from `cdn.jsdelivr.net`. If that's blocked (ad
blockers, school firewalls, **or sandboxed dev environments** — this includes the
network policy in some Claude Code remote environments), the app shows a full-page
"Connection Error" screen and nothing renders. See Testing below.

## State model

There's one global `state` object and a single `render()` dispatcher (~line 1689) that
switches on `state.screen` (`'landing'`, `'teacherSetup'`, `'teacherLobby'`,
`'teacherLive'`, `'studentJoin'`, `'studentRoom'`, `'phoneRemote'`, etc.) to call the
matching `renderXxx()` function. Each `renderXxx()` rebuilds its slice of the DOM via
`innerHTML` template strings and re-wires event handlers — there's no virtual DOM or
component framework. Screens generally own a polling `tick()` that re-fetches from
Supabase and calls `render()` again.

## Room types

Six room types, identified by `state.type` / `s.type`:
`wordcloud`, `brainstorm`, `sticky`, `ranking`, `mc` (single multiple-choice question),
`poll` (multi-question quiz, optionally with participant nicknames via
`requireNames`).

For each type there's roughly a matching trio of functions:
- **Setup** (host builds the room): `renderWordCloudSetup`, `renderBrainstormSetup`,
  `renderStickySetup`, `renderRankingSetup`, `renderMCSetup`, `renderPollSetup` /
  `renderPollBuildStage`.
- **Live/host view**: `renderTeacherLive` (~3299) is the shared shell (QR, controls,
  presentation mode); it delegates board rendering to `renderTeacherStage` →
  `renderRankingStage`, `renderStickyStage`, `renderBrainstormStage`, `renderMCStage`,
  `renderCloudStage`.
- **Participant view**: `renderStudentRoom` (~5445) dispatches to
  `renderStudentRoomRanking`, `renderStudentRoomBrainstorm`, `renderStudentRoomSticky`,
  `renderStudentRoomWordCloud`, `renderStudentRoomMC`.

`poll` rooms with `requireNames` get an extra pre-flight: `renderTeacherLobby` (~2741)
is a waiting room where the host reviews/removes nicknames before starting, and the
"Phone Remote" (`renderPhoneRemote`, ~4088) mirrors that nickname-review UI instead of
the vote-approval inbox it shows for other room types — see git history on this file
for context if extending it further.

Board downloads (PDF/JPEG via `html2canvas` + `jspdf`, and CSV built from state) live
in `exportBoard` / `boardToCSVRows` (~6259–6322) and are wired per room type into each
"Download Board" dropdown — there are multiple near-duplicate copies of that dropdown
markup across teacher/student views; when changing one, grep for
`download-dropdown-menu` to catch the others.

## Conventions

- All styling is inline `style="..."` attributes; there is very little shared CSS by
  class. Match this when adding UI rather than introducing a new stylesheet pattern.
- User-provided text always goes through `escapeHtml()` (~1425) before being
  interpolated into a template string — never skip this for anything sourced from a
  participant.
- No comments by default in this codebase; keep that up unless documenting a genuinely
  non-obvious constraint.
- Emoji are used liberally in UI copy (📱 🤝 🏆 📊 ⚡ etc.) — this is intentional brand
  voice, not something to clean up.

## Testing / verification

There is no test suite and no build step to typecheck against. To verify a change:
1. `node --check` on the extracted `<script>` contents is a fast way to catch syntax
   errors (see prior sessions' scratchpad for the extraction one-liner).
2. For real behavior, this app needs a browser and a working Supabase connection.
   **The Supabase JS client loads from `cdn.jsdelivr.net` — if that's blocked in your
   environment (common in sandboxed Claude Code sessions), the whole app fails to
   render and shows a "Connection Error" screen instead.** In that case:
   - Don't conclude the app is broken — check whether the CDN request itself failed
     (browser console / network errors) before debugging app logic.
   - For isolated UI/interaction logic (e.g. a toggle, a client-side computation),
     extract just the relevant HTML/JS snippet into a standalone test file rather than
     trying to boot the full app — this sidesteps the CDN dependency entirely and was
     the working approach in earlier sessions on this repo.
   - If you can reach `cdn.jsdelivr.net`, the full app can be exercised normally with
     Playwright against a local static server (`python3 -m http.server`).
