# Syntila Home Contract (v1)

## Overview

The Syntila **Home** surface is the personal collaboration and attention hub for a user across all their Spaces.

Home is **not** a metrics dashboard of infrastructure counts (e.g. number of Spaces, connected Workers, ready Workers, or idle execution queues). Infrastructure and entity management reside in their dedicated navigation areas (Spaces, Workers, Workers, Runs).

Instead, Home answers three fundamental questions for the user:
1. **What needs my attention?**
2. **What was I working on with my team and AI?**
3. **What is new in Syntila and in my connected AI tools?**

```text
HOME
│
├── 1. For You
│    └── Actionable items requiring or deserving attention
│
├── 2. Continue Working
│    └── Recent relevant Threads with collaboration context
│
├── 3. What's New
│    └── Syntila product release updates and feature announcements
│
└── 4. AI Updates
     └── Model and capability updates relevant to available Workers
```

---

## The Four Core Responsibilities

### 1. For You (Triage Surface vs Notification Center)
- **Distinct Responsibilities:**
  - **Notification Center:** Answers *"What happened?"* Full chronological timeline of events, reads/unreads, and historic notifications.
  - Notification Center opens beside the desktop sidebar (following its resized width or collapsed icon rail) and as a full-width bottom sheet on mobile, with the Inbox header and content aligned to the top of the available window. Close, mark-read, invitation decisions, and record navigation retain their existing behavior.
  - Notification Center records show a status title once, with optional specific event details and Space/Thread location. Generic status restatements are omitted. Each record has one leading status icon; its color indicates attention and read state, with accessible priority/read labels. Records have no trailing icons or visible priority text.
  - **Home ("For You"):** Answers *"What should I care about?"* A strictly bounded (maximum four latest items) triage surface displaying only items that demand the user's active attention or decision.
- **Actionable eligibility:** Include pending invitations from the authoritative invitation list, input/approval requests, execution failures, Worker/Worker problems, and open findings. Exclude completion/informational events even when they have an Open action. Historical invitation notifications cannot keep accepted or declined invitations on Home. Only unread items appear on Home. Opening a card marks its notification read before navigation and removes it from Home; the read record remains in Inbox. Pending invitations and aggregate findings without a server notification use session-local read IDs, cleared on logout.
- **Home Selection:** Deduplicate authorized attention items, filter out read items, order newest first by event timestamp, and show at most four. Preserve source order for equal or missing timestamps.
- **Navigation & CTA:**
  - Explicit header CTA: `View all notifications →` opening the full Notification Center.
  - No item-count badge appears beside For you.
- **Card Structure:** Use the same bordered, rounded card and responsive two-column layout as Continue Working: category, title, right-aligned relative timestamp, and contextual preview. The whole record invokes its primary navigation action; no Inspect/Review/Open button is shown. Invitations retain explicit Accept and Decline controls.
- **Absence Behavior:** If nothing requires attention, the section renders `const SizedBox.shrink()` (zero filler/empty placeholder text like `"Nothing needs your attention"`).

### 2. Continue Working (Phase 8 & Phase 9: Recent-Work Ranking)
- **Purpose:** Fast resumption of ongoing collaborative work in context. Spaces are broad; the true return destination is the active Thread/conversation.
- **Capacity:** Shows up to four latest authorized, non-archived Threads (two columns on wide screens).
- **Card Structure:**
  1. **Space Name:** Uppercase tracked label (e.g., `SYNTILA DEVELOPMENT`, `WEBSITE`).
  2. **Thread Title:** Prominent bold title (e.g., `Worker Sessions`, `Landing Page`).
  3. **Relative Time:** When the Thread last had activity (e.g., `23 min ago`, `Yesterday`).
  4. **Last Message:** A short preview (whitespace collapsed, at most two lines) prefixed with its sender, e.g. `Alex: We should persist the...`. The sender comes from the thread list `briefAuthorName` (member display name, or the Worker display name for AI answers).
  5. **Navigation:** The whole card is clickable and opens the Thread conversation (`AxNavigation.thread(spaceId, threadId)`); there is no separate button.
- **Selection:** Order by descending `lastMeaningfulActivityAt`, with dated items before undated items and stable source order for ties. Active/unresolved state does not displace newer Threads. The Home cache adapter supplies up to four items. Archived Spaces/Threads and inaccessible resources remain excluded.
- **Absence Behavior:** Omitted if no space or thread history exists.

### 3. What's New
- **Purpose:** Product updates, capability announcements, and changelogs.
- **Characteristics:**
  - Benefit-first descriptions (not git commits)
  - Human-readable release date
  - Full text shown inline on Home; the full changelog is available from `See all`
  - Targetable audience / per-user read state tracking

### 4. AI Updates
- **Purpose:** Relevant model and capability changes for supported AI Workers.
- **Relevance Filter:** Scoped strictly to the Workers connected or available to the user's spaces (e.g., ChatGPT model upgrades shown only to users with ChatGPT Workers enabled).
- **Not Generic AI Industry News:** Covers only changes that directly affect what the user can execute inside Syntila (e.g., *"GPT-5 is now available in your ChatGPT Worker"* vs generic press announcements).

---

## Established-User Home Invariants & Removals

The following legacy concepts are **prohibited** from established-user Home:
- ❌ Spaces count metric card
- ❌ Workers count metric card
- ❌ Ready Workers count metric card
- ❌ Recent Spaces plain list (replaced by *Continue Working* threads)
- ❌ Permanent `"No active Runs"` card
- ❌ Static `"Nothing needs your attention"` filler
- ❌ `"Archived Spaces"` header button
- ❌ Generic `"Your execution capacity at a glance"` subtitle
- ❌ Onboarding / Getting Started cards mixed into the dashboard

---

## Clean Separation of Home Surfaces

```text
HomePage (Dispatcher)
    │
    ├── isNewUser == true  (spaces.isEmpty)
    │     └── NewUserHome
    │           ├── (Priority if invitations.isNotEmpty) Join a Space card
    │           ├── ("or" divider if invitations.isNotEmpty)
    │           ├── Create your first Space card
    │           ├── How Syntila works (value foundation cards)
    │           └── Advanced local execution (Want to use AI or tools running on your computer?)
    │
    └── isNewUser == false (spaces.isNotEmpty)
          └── EstablishedUserHome
                ├── 1. For You (attention items + pending invitations)
                ├── 2. Running Now (if active runs)
                ├── 3. Continue Working (active threads)
                ├── 4. What's New in Syntila (product updates)
                └── 5. AI Updates (scoped model updates)
```

### 1. NewUserHome
- **Condition:** Active when `spaces.isEmpty`.
- **Experience & Onboarding Hierarchy:**
  ```text
  Create / Join Space
          ↓
  Collaborate
          ↓
  Add AI
          ↓
  Advanced local execution if required
  ```
  - Dedicated header: `Welcome to Syntila` / `Bring your people and AI together.`
  - **Priority Invitation Card** (when `invitations.isNotEmpty`):
    - Displays `Join a Space` with count badge (*"You have N invitations."*).
    - Inlines invitations with direct `Accept` and `Decline` actions.
    - Followed by an `or` separator.
  - **Primary Space Action**:
    - `Create your first Space` (*"Start a shared space for people, conversations and AI."*).
    - `Create Space →` action button.
  - **How Syntila works** value foundation:
    - `People first`: Invite teammates, family, and collaborators to work together with shared AI.
    - `Private credentials`: Share AI access without exposing private keys.
    - `Shared conversations`: Maintain shared space context across members.
  - **Advanced Local Execution Path** (visually secondary at bottom):
    - Title: *"Want to use AI or tools running on your computer?"*
    - Description: *"Connect Syntila Worker to make local Workers available to your Spaces."*
    - Action: `Connect Worker →`
  - Completely omits established dashboard sections (`For you`, `Continue working`, `What's new in Syntila`, `AI updates`).

### 2. EstablishedUserHome
- **Condition:** Active when `spaces.isNotEmpty`.
- **Experience:**
  - **For You**: Prioritizes attention items, thread input requests, and pending invitations.
  - **Running Now**: Conditionally visible when active runs exist.
  - **Continue Working**: Clickable Thread cards with the last message and its sender.
  - **What's New in Syntila**: Official product updates.
  - **AI Updates**: Scoped AI capability news for available worker types.
  - Strictly omits onboarding cards and getting-started tutorials.

---

## Attention Item Domain Abstraction (Phase 7)

To keep `HomePage` and `_ForYouItemTile` decoupled from backend schemas, realtime event shapes, and navigation routing plumbing, Home utilizes a presentation domain abstraction:

```text
AxHomeAttentionItem
├── id: String
├── type: AxHomeAttentionType (spaceInvitation, needsInput, approvalRequired, executionFailed, executionCompleted, workerProblem, workerOffline)
├── priority: int? (explicit priority override or derived default order)
├── title: String
├── description: String
├── spaceId?: String
├── threadId?: String
├── workerId?: String
├── timestamp?: DateTime
├── timestampDisplay?: String
├── primaryAction?: AxHomeAttentionAction (label, onPerform closure, isDestructive)
├── secondaryAction?: AxHomeAttentionAction (label, onPerform closure, isDestructive)
└── read: bool
```

### Decoupling Guarantees
1. **Pure Presentation Tile (`_ForYouItemTile`):**
   - The tile does not handle routing switches, invitation models, or backend-specific structures.
   - It exclusively invokes `item.primaryAction?.onPerform()` and `item.secondaryAction?.onPerform()`.
2. **Projector Projection (`AxHomeAttentionProjector.space(...)`):**
   - Transforms diverse inputs (invitations, background findings, system notifications) into normalized `AxHomeAttentionItem`s.
   - Binds concrete callback closures into `AxHomeAttentionAction` instances (`Accept`, `Decline`, `Review →`, `Inspect →`, `Fix →`, `Connect →`, `Open →`).
   - Orders by event recency and selects the latest four items.

---

## Cached / Local Read Model Architecture (Phase 10)

Home is designed as a **pure projection** of already synchronized client-side state:
- **No Reload Storms on Navigation:** Navigating `Space A → Home → Space B → Home` consumes shared in-memory stores (`store.spaces`, `store.executionChanges`, `store.invitations`, `store.catalogs.workers`, `store.notifications`, `store.productUpdateReadStates`) via reactive `ListenableBuilder` and `AxQueryBuilder`.
- **Zero Independent Server Reloads:** Opening Home never triggers independent HTTP fetch bursts for entities that are already managed by Syntila's background sync engine.

---

## What's New & Product Update Lifecycle (Phases 11–15)

### 1. ProductUpdate Domain Model (Phase 11)
```text
AxProductUpdate
├── id: String
├── slug: String
├── title: String
├── summary: String
├── details?: String
├── category: AxProductUpdateCategory (feature, improvement, security, workflow, collaboration, worker)
├── publishedAt: DateTime / String
├── minimumAppVersion?: String
├── maximumAppVersion?: String
├── actionType?: String
├── actionTarget?: String
├── imageUrl?: String
├── audience: String (e.g. 'all', 'collaborators', 'developers')
├── status: AxProductUpdateStatus (draft, published, archived)
├── actionUrl?: String
└── learnMoreUrl?: String
```

### 2. Server-Driven Update Lifecycle (Phase 12)
- **Status Filtering:** Established-user Home only presents `published` updates (draft and archived updates are filtered out in standard production mode).
- **Version Compatibility:** Respects `minimumAppVersion` and `maximumAppVersion` constraints against the running AX client build.

### 3. Per-User Read State Tracking (Phase 13)
```text
AxUserProductUpdateState
├── userId: String
├── updateId: String
├── seenAt?: DateTime     (appeared on Home)
├── openedAt?: DateTime   (user opened full detail / changelog)
└── dismissedAt?: DateTime (historical state retained; Home ignores it)
```
- **Unread Badge Calculation:** `AxProductUpdateService.computeUnreadCount(...)` counts published, version-compatible updates where `seenAt == null` and `dismissedAt == null`.
- **Badge Display:** The Home section title shows no unread count; the count is used only for analytics.

### 4. Home Presentation for What's New (Phase 14)
- **Capacity:** Shows up to four newest published, version-compatible updates. Home ignores historical dismissal state; no Hide control appears on Home or the full changelog.
- **Tile Elements:**
  1. Distinct category icon plus badge pill (`[COLLABORATION]`, `[WORKFLOW]`, `[SECURITY]`, `[WORKER]`, `[FEATURE]`, `[IMPROVEMENT]`).
  2. Date format: e.g. `Oct 7, 2026`, right-aligned and derived from the publication timestamp.
  3. Bold title, full summary, and full details text.
  4. Rows are informational and not clickable; `See all` opens the full changelog.
- **Empty-State Omission:** If no eligible updates exist, the section collapses completely (`const SizedBox.shrink()`) with **zero** filler text (never displays `"Nothing new."`).

### 5. Full What's New Surface (`AxWhatsNewDialog`, Phase 15)
- **Entry Point:** Header `See all` action button on Home.
- **Monthly Grouping:** Groups changelog entries chronologically by month and year (`October 2026`, `September 2026`, etc.).
- **Rich Changelog Items:** Displays expanded markdown/details, publication dates, category badges, and external/deep-link CTAs. The full page inherits Home’s content width (up to 840 px) and has no Hide control.

---

## AI Capability Updates as Distinct Domain Model (Phase 16)

AI and model capability changes are **distinct** from generic Syntila application releases. Model additions, deprecations, tool profile updates, and provider capability adjustments are modeled independently.

### 1. AiCapabilityUpdate Domain Model
```text
AxAiCapabilityUpdate
├── id: String
├── workerProfileId: String (e.g. 'chatgpt', 'gemini', 'claude', 'ollama')
├── provider?: String       (e.g. 'openai', 'google', 'anthropic', 'meta')
├── type: AxAiCapabilityUpdateType
│   ├── model_added
│   ├── model_removed
│   ├── model_deprecated
│   ├── capability_added
│   ├── capability_changed
│   ├── profile_updated
│   └── authentication_changed
├── modelId?: String          (e.g. 'gpt-4o', 'gemini-2.5-pro')
├── modelDisplayName?: String (e.g. 'GPT-4o', 'Gemini 2.5 Pro')
├── title: String
├── summary: String
├── publishedAt: DateTime / String
├── actionTarget?: String
└── minimumProfileVersion?: String
```

### 2. Presentation & Filtering on Home
- **Scoped by Active Workers:** When Workers are available to the user, Home filters AI capability updates to highlight relevant provider/worker capabilities.
- **Capacity:** Home shows up to four newest relevant updates; `See all` retains all relevant updates and inherits Home’s content width. No Hide controls appear.
- **Card Presentation (`_AiUpdateCard`):** Displays the original Worker brand icon (generic fallback for unknown Workers), worker name, category pill badge (e.g. `[MODEL ADDED]`, `[CAPABILITY ADDED]`), right-aligned publication date including year (`Oct 7, 2026`), bold title, and the full update text. Rows are informational: not clickable and without a `Configure →` action; `See all` opens the AI updates dialog.

---

## User-Relevant Worker Accessibility & Dynamic AI Update Filtering (Phase 17)

Home filters AI updates to show **only** changes for Workers the user can actually access:

### 1. Accessibility Resolution Pipeline (`AxAiCapabilityUpdateService.resolveAccessibleWorkerProfileIds`)
```text
Available Worker Profiles
  ├── User Worker Workers (e.g., local ChatGPT Worker)
  ├── Shared Space Threads (e.g., space thread with Gemini Worker lead/config)
  └── Space Settings Worker Grants (e.g., sharedWorkers / workerGrants)
        ↓
AI Capability Updates Catalog
        ↓
Strict Accessibility Filter
        ↓
Home Surface
```

### 2. Strict Filtering Guarantees
- **No Irrelevant Provider News:** If the user has ChatGPT only, Gemini/Claude updates are strictly omitted.
- **Shared Access Inclusion:** If a collaborator gains access to a Worker profile through a shared Space Thread or grant, relevant updates for that Worker automatically become visible on Home.
- **Zero-State Omission:** If the user has zero accessible workers or no updates match their accessible workers, the AI updates section collapses completely (`const SizedBox.shrink()`) without placeholder clutter.

---

## Separation of Model Discovery from Editorial Updates (Phase 18)

Not every capability change requires a human-authored news article. Syntila distinguishes:
1. **System-Generated Discovery Updates (`AxAiCapabilityUpdateSource.systemGenerated`):**
   - Automatically synthesized when Tool Profile or provider model discovery detects newly available or retired models (e.g. `[A, B] -> [A, B, C]`).
   - Title: `New model available` / `Model retired`.
   - Summary: `Model <modelId> is now available for your <WorkerName>.`
2. **Editorial Updates (`AxAiCapabilityUpdateSource.editorial`):**
   - Curated announcements for major AI releases with customized descriptions, guidance, and deep-link actions.

### Precedence & Merging (`AxAiCapabilityUpdateService.mergeUpdates`)
- When both curated editorial updates and automated model discovery items exist for the same `workerProfileId:modelId` pair, the **curated editorial announcement takes precedence** to avoid redundant noise.
- Both types are formatted and presented uniformly within the "AI updates" surface.

---

## Ephemeral "Running now" Execution Surface (Phase 19)

Home avoids permanent or static "Active Runs" cards that clutter the screen when no work is executing.

### 1. Ephemeral Display Contract
- **Active Execution Only:** The "Running now" section appears **only** when an execution is genuinely active (`run != null && run.isRunning` where status is `RunStatus.running` or `RunStatus.active`).
- **Rich Card Presentation (`_RunningNowCard`):**
  - **Objective:** Prominent title (e.g., `Landing page review`).
  - **Worker & Model Metadata:** Concise context badge (e.g., `ChatGPT · Model X · High`).
  - **Thread Hierarchy:** Navigation path (e.g., `Website / Landing Page`).
  - **Duration & Progress:** Active execution time or task counts (e.g., `Running for 1m 42s` or `2/5 tasks completed`).
  - **Direct CTA:** `Open →` button navigating directly into the executing Thread/Run view.
- **Zero-State Omission:** When nothing is running (`run == null` or run has reached a terminal/non-running state like `completed`, `failed`, `cancelled`), the section is completely omitted (`const SizedBox.shrink()`), preventing empty-state clutter.

---

## Conditional Home Composition & Dynamic User Tailoring (Phase 20)

Established Home composition is completely dynamic and modular, evaluating conditions for each section independently:

```text
Established Home
├── if attentionItems:    -> For You
├── if activeExecutions:  -> Running Now
├── if recentWork:        -> Continue Working
├── if productUpdates:    -> What's New
└── if aiUpdates:         -> AI Updates
```

---

## Visual Hierarchy & Attention Emphasis (Phase 21)

Established Home establishes a strict visual hierarchy where actionable and operational signals take precedence over secondary discovery and changelog content:

```text
Home Hierarchy Order
├── 1. For You          [Strongest]  (Approvals, Failures, Invitations, Offline issues)
├── 2. Running Now      [Dynamic]    (Active executions with live telemetry)
├── 3. Continue Working [Primary]    (Latest four Threads)
├── 4. What's New       [Secondary]  (Subdued product releases & changelog)
└── 5. AI Updates       [Secondary]  (Subdued model availability & capability changes)
```

### 1. Hierarchy Rules & Visual Weight Guarantees
- **Action Signals First:** Product news and AI model changes must never visually compete with, overshadow, or distract from an approval request, execution failure, Worker disconnection, or space invitation.
- **For You Section Prominence:**
  - Placed at the very top of Home above all executions and threads.
  - Distinct high-contrast card border and surface styling.
  - High-visibility semantic category badges (orange for approvals/input, red for execution failures, amber for offline Workers, primary for invitations).
  - Primary call-to-action buttons (`FilledButton` for primary actions like "Review →" or "Accept") ensure direct operational resolution.
- **Running Now Section:**
  - Positioned immediately below For You when active runs exist, offering real-time visibility and direct jump navigation into active execution trees.
---

## Row-Based Section Flow & Reduced Card Density (Phase 22)

To prevent Home from feeling like a fragmented admin dashboard, Home replaces arbitrary independent card wrappers with clean section row flows:

```text
Section Row Composition
├── For You:        Header -> Row [Item] -> Divider -> Row [Item] ...
├── What's New:     Header -> Row [Update] -> Divider -> Row [Update] ...
└── AI Updates:     Header -> Row [Capability] -> Divider -> Row [Capability] ...

Reserved Card Surfaces
├── Continue Working:   Rich Thread grid cards (collaboration & snippet context)
├── Running Now:        Highlighted ephemeral execution card (telemetry & live CTA)
└── Onboarding:         Welcome & initial value cards (first-time walkthrough)
```

### 1. Architectural Guidelines
- **Clean Worker Flow:** `For You`, `What's New`, and `AI Updates` render items as lightweight list rows directly within their section with subtle hairline dividers, eliminating visual clutter from nesting boxes inside boxes.
- **Card Purpose Preservation:** Large cards are reserved strictly for rich content containers where multi-dimensional metadata benefits from a bounded spatial enclosure:
  - **`Continue Working`:** Thread title, space badge, snippet previews, collaborator identities, and jump actions.
  - **`Running Now`:** High-priority active execution telemetry, objective, elapsed time, and direct Worker navigation.
  - **`Onboarding`:** First-turn welcome cards and setup milestones.

---

## Home Header & Contextual Greeting (Phase 23)

Established-user Home strips away generic marketing subtitles to deliver an uncluttered, distraction-free Home header:

```text
Established Home Header
├── Title: "Home" (28px Bold)
└── Subtitle (Optional): Contextual greeting (e.g. "Good morning, Vitalii.") or explicit custom greeting
```

### 1. Architectural Rules
- **No Marketing Subtitles:** Legacy marketing taglines like `"Your execution capacity at a glance."` are permanently eliminated. The Home content underneath speaks for itself.
- **Contextual Greeting:**
  - When `greeting` is explicitly provided, it renders directly beneath `Home`.
  - When `userName` is provided, Home dynamically derives an appropriate time-of-day greeting:
    - Hour `< 12`: `Good morning, <userName>.`
    - Hour `12..17`: `Good afternoon, <userName>.`
    - Hour `18..23`: `Good evening, <userName>.`
  - When neither `greeting` nor `userName` is supplied, `Home` renders cleanly as a standalone title without residual spacing or empty subtitle lines.

---

## Archive Management in Navigation Context & Exclusion from Home (Phase 24)

Home is a focused attention and collaboration hub; it is not a miscellaneous launchpad for administrative utility buttons or secondary shortcuts.

```text
Archive Management Scope
├── Navigation Context (App Menu / Sidebar): "Archived Spaces" dialog & restore actions
├── Space Context (Space / Thread views): "Archive" / "Restore" actions
└── Home: Excluded (Zero utility buttons or archive shortcuts)
```

### 1. Architectural Rules
- **Compact Archived Space Cards:** The Archived Spaces page places a visible circular ⋮ menu button at the top-right of each card instead of a bottom button row. Restore and Delete remain available through that menu; deletion requires confirmation. Menu targets and items are 48 logical pixels high for touch access. While a mutation is pending, its card menu is disabled and displays progress. Empty or whitespace-only descriptions are omitted along with their spacing, allowing cards to shrink to their content. The responsive one/two-column layout remains unchanged.
- **No Archive Buttons on Home:** The legacy `"Archived Spaces"` button previously located beneath the title is permanently removed from Home.
- **Dedicated Navigation Placement:** Archive discovery and space restoration live cleanly inside the global application menu (`AppMenu`) and sidebar (`AppSidebar`), or inside the Space management surface (`SpacePage`), preserving Home purely for active attention, active execution, active threads, and relevant updates.

---

## Integrated Invitation UX & Single Source of Truth (Phase 25)

Invitations remain prominent across Syntila without maintaining disparate, disconnected invitation models or state pools.

```text
AxSpaceInvitation Reactive Stream
               ↓
    AxCollaborationMutations
               │
  ┌────────────┼────────────┬─────────────┬──────────────┐
  ▼            ▼            ▼             ▼              ▼
Home Card   For You     Notification   Sidebar Tree   Space
(New User)  (Attention)    Badge       (Pending)     Membership
```

### 1. Unified State & Immediate Synchronization
- **Single Source of Truth:** `store.invitations` and `store.collaboration` own the canonical state and lifecycle for space invitations across all presentation projections.
- **Projections over the Same State:**
  - **New-User Home:** `Join a Space` priority card.
  - **Established-User Home:** Recent `Space invitation` cards in the `For You` attention section via `AxHomeAttentionProjector`.
  - **Notification Center & Inbox:** `Pending invitations` section within `_showNotifications` dialog.
  - **Sidebar Space Tree:** `Pending invitations (N)` group in `SpaceTree`.
- **Immediate Multi-Surface Updates:**
  - Accepting an invitation from Home executes `store.acceptInvitation(invite)` which optimistically updates both the `invitations` and `spaces` stores.
  - Instantly without page reload or manual refetch:
    1. Home removes the invitation item.
    2. Notification badge decreases.
    3. Sidebar `SpaceTree` adds the joined space and clears the pending invitation entry.
    4. Space membership queries are refreshed.
    5. The client transitions directly into the newly joined space conversation space.

---

## Actionable Deep-Link Destinations for Every Home Item (Phase 26)

Home never displays passive information or dead-end cards without an obvious next action. Every item on Home resolves to an exact, concrete destination:

```text
Home Items & Canonical Deep-Link Destinations
├── 1. Space Invitation   → Accept / Decline actions & direct Space entry
├── 2. Needs Input / Review → Exact Thread conversation context
├── 3. Execution Failure    → Exact Thread & Run failure inspector
├── 4. Worker/Worker Prob→ Exact Worker configuration & reconnection surface
├── 5. Running Now          → Exact active Thread & live execution view
├── 6. Continue Working     → Exact Thread conversation
├── 7. What's New           → Update detail dialog & changelog
└── 8. AI Capability Update → Relevant Worker & model configuration
```

### 1. Architectural Rules
- **No Dead-End Content:** If an item exists on Home, it must provide a direct primary action button or interactive target routing to its operational resolution.
- **Context-Preserving Routing:**
  - `onOpenThread(spaceId, threadId)` is prioritized over broad space landing pages for conversation turns, unresolved input requests, reviews, and recent work.
  - `onOpenWorkers()` is directly bound to offline Workers, Worker credential faults, and AI model configurations.
---

## Progressive Loading Strategy & Fault-Isolated Section Rendering (Phase 27)

Home avoids monolithic, all-or-nothing data fetches. Rendering progresses through decoupled layers while strictly isolating potential failures:

```text
Progressive Rendering Flow
├── 1. Cached Home (Immediate render from in-memory reactive stores)
├── 2. Attention Refresh (Background sync for invitations, approvals, faults)
├── 3. Recent Work Refresh (Background sync for active conversation threads)
└── 4. Updates Refresh (Changelog & AI model capability background fetches)
```

### 1. Architectural Guarantees & Fault Isolation
- **Non-Blocking Execution:** Home never stalls rendering while awaiting secondary or background service payloads.
- **Strict Section Fault Isolation:**
  - An error, timeout, or schema failure in the **What's New** product updates service will **never** prevent `For You`, `Running Now`, or `Continue Working` from rendering.
  - An error or empty response in the **AI Updates** capability service will **never** produce a whole-page error or crash the application.
  - If a secondary section's data projection throws an exception, it is caught locally and gracefully collapses to `const SizedBox.shrink()`, preserving primary triage and daily workflows intact.
---

## Offline & Degraded Connectivity Behavior (Phase 28)

When network connectivity is disrupted or AX cannot reach Cloud services, Home preserves user workflow continuity instead of blanking out or rendering full-page error blocks:

```text
Offline Home State
├── Small Connectivity Indicator (Header: "Offline · Cached data")
├── Cached Continue Working (Full read and local conversation resumption)
├── Cached What's New & AI Updates (Full read of locally stored announcements)
└── Server-Dependent Actions (Gracefully degraded/disabled without disrupting read access)
```

---

## Notifications Cleanup & Normalized Domain Terminology (Phase 29)

Home and the Notification Center utilize a normalized domain model structured strictly around the five fundamental Syntila entities:

```text
Normalized Notification Domain
├── 1. Thread   (threadNeedsInput, threadCompleted, threadFailed)
├── 2. Workflow Run (workflowRunCompleted, workflowRunFailed, workflowRunNeedsApproval)
├── 3. Worker       (workerCredentialProblem, workerInstallFailed)
└── 5. Space      (spaceInvitationReceived)
```

### 1. Architectural Rules & Normalization
- **No Ambiguous "Run" Assumptions:** Notifications distinguish between ongoing Thread conversational turns and background Workflow Run executions.
- **Accurate Navigation Target Resolution:**
  - `AxNotificationTarget.thread` → Deep-links directly to `AxNavigation.thread(spaceId, threadId)`.
  - `AxNotificationTarget.workflowRun` → Deep-links directly to `AxNavigation.run(spaceId, runId)`.
  - `AxNotificationTarget.workers` → Opens the Workers page.
  - `AxNotificationTarget.space` → Deep-links to `AxNavigation.space(spaceId)`.
- **Actionability & Priority Mapping:**
  - High priority: `threadNeedsInput`, `threadFailed`, `workflowRunNeedsApproval`, `workflowRunFailed`, `workerCredentialProblem`.
  - Normal priority: `workerInstallFailed`, `spaceInvitationReceived`.
  - Low priority: `threadCompleted`, `workflowRunCompleted`.
- **Home Triage Alignment:** `AxHomeAttentionProjector` maps normalized notification events cleanly into `AxHomeAttentionItem` triage rows with primary navigation bound to the whole card, plus explicit invitation decisions.

---

## Privacy & Authorization Enforcement on Home Aggregation (Phase 30)

Home aggregation strictly respects authorization and permission boundaries across all sections and data sources.

```text
Authorization Boundary on Home Aggregation
├── Cloud Read-Model & APIs ──► Returns only authorized Spaces & Threads for the authenticated user
│                                (D1 queries scoped by space_memberships; 403/404 on ungranted resources)
│
└── Client Aggregation Projections
    ├── For You (AxHomeAttentionProjector) ──► Strict exclusion of items referencing revoked/non-member spaces
    ├── Running Now                         ──► Active runs for revoked/non-member spaces are suppressed
    ├── Continue Working (Recent Work)      ──► Only authorized space threads are ordered by recency and rendered
    └── AI Updates (AxAiCapabilityUpdate)   ──► Filtered strictly against accessible Workers & member spaces
```

### 1. Privacy Guarantees
When a user's access to a Space, Worker, or Worker is revoked, the user must **never** see:
- Space name
- Thread title
- Worker activity & active run details
- Conversation message snippets & previews
- AI capability updates tied exclusively to inaccessible Workers

### 2. Multi-Layer Enforcement
- **Backend / Read-Model APIs:** Cloud endpoints (`/api/spaces`, `/api/spaces/:id/threads`, `/api/spaces/:id/threads/:wsId/conversations`) enforce SQL membership joins and `authorizeRequest` checks before returning data. Revoked spaces are never returned in listing APIs.
- **Client Projections:** Client-side projectors (`AxHomeAttentionProjector`, `EstablishedUserHome`, `AxRecentWorkRanker`, `AxAiCapabilityUpdateService`) validate every item against the user's active authorized space set (`spaces.map((p) => p.id)`). Any cached or stale item referencing an unauthorized or revoked space ID is immediately filtered out before rendering.

---

## Home API / Read Projection Model (Phase 31)

To provide an efficient startup request for web and client applications while strictly preserving proper domain ownership, Syntila exposes a purpose-built read model endpoint:

```http
GET /api/home
GET /home
```

### 1. Conceptual Read Projection Contract

The response aggregates five focused slices into a single unified JSON payload:

```json
{
  "attention": [
    {
      "id": "invitation-1",
      "type": "spaceInvitation",
      "priority": 1,
      "title": "Invited to Alpha Space",
      "description": "Owner invited you to join Alpha Space as editor",
      "spaceId": "proj-1",
      "timestamp": "2026-10-08T06:00:00.000Z",
      "read": false
    }
  ],
  "running": [
    {
      "id": "req-1",
      "spaceId": "proj-1",
      "threadId": "ws-1",
      "workerId": "codex",
      "workerType": "claude-code",
      "status": "running",
      "title": "Refactoring Home API",
      "createdAt": "2026-10-08T06:10:00.000Z",
      "updatedAt": "2026-10-08T06:12:00.000Z"
    }
  ],
  "recentWork": [
    {
      "spaceId": "proj-1",
      "spaceName": "Alpha Space",
      "threadId": "ws-1",
      "threadTitle": "Feature Implementation",
      "updatedAt": "2026-10-08T06:12:00.000Z",
      "activeCollaborators": ["User A"],
      "latestSnippet": "Latest message preview"
    }
  ],
  "productUpdates": [
    {
      "id": "upd-1",
      "slug": "v8-home",
      "title": "Home V2 Released",
      "summary": "Clean section rows and startup hydration",
      "category": "feature",
      "publishedAt": "2026-10-08T00:00:00.000Z",
      "audience": "all",
      "status": "published"
    }
  ],
  "aiUpdates": [
    {
      "id": "ai-1",
      "title": "Gemini CLI Worker Available",
      "summary": "Fast reasoning and native tools integration",
      "type": "model",
      "publishedAt": "2026-10-08T00:00:00.000Z",
      "audience": "all",
      "status": "published"
    }
  ]
}
```

### 2. Architecture & Domain Integrity Principles
1. **Not a Canonical Store:** `GET /api/home` does not introduce dedicated D1 tables or shadow stores. It computes a fast, read-only projection on the fly across canonical tables (`spaces`, `space_memberships`, `space_invitations`, `work_requests`, `threads`, `discussion_messages`, and worker catalogs).
2. **Strict Authorization Scoping:** Every entity returned in `attention`, `running`, and `recentWork` is strictly joined against the authenticated `user_id`'s active `space_memberships`. Revoked or inaccessible spaces are excluded at the database query layer.
3. **Graceful Degraded / Progressive Rendering:** Web and mobile clients can hydrate their local reactive stores using `AxHomeReadModel.fromJson(data)` upon initial launch while retaining progressive per-section refresh capabilities and offline caching resilience.

---

## Realtime Updates & Reactive Home Hydration (Phase 32)

Home reacts dynamically and immediately to live Syntila transport and realtime domain events without requiring any manual user refresh:

```text
Realtime Domain Event Flow
├── invitation.received        ──► Appears in "For You" (and "Join a Space" card for 0-space users)
├── thread.needs_input     ──► Appears in "For You" with direct "Review →" thread link
├── thread.completed       ──► "Running Now" card clears; review item appears in "For You" ("Open →")
├── worker.problem / offline   ──► Appears in "For You" with direct "Fix →" / "Connect →" action
└── product.update.published   ──► Live update added to What's New; unread badge counter increments
```

### 1. Zero-Polling Reactive Architecture
- `_homeView()` registers merged reactive listeners across `store.spaces`, `store.executionChanges`, `store.invitations`, `store.unreadNotifications`, `store.productUpdateReadStates`, and `store.productUpdatesNotifier`.
- Background WebSocket transport messages invoke `_recordNotification(event)` and `_refreshRealtimeFeatures(type, event: event)`, immediately dispatching state updates to in-memory stores and triggering granular widget rebuilds.

---

## Canonical Scenario Testing Matrix (Phase 33)

The Syntila Home surface is formally verified against a 20-point canonical test matrix ensuring complete domain correctness, lifecycle handling, authorization guarantees, and responsive rendering across all form factors:

| # | Scenario | Expected Behavior | Verification Status |
|---|---|---|---|
| 1 | **Brand-new account** | Renders `NewUserHome` onboarding hero, "Create your first Space", value cards; suppresses dashboard sections | Verified (`home_page_test.dart`) |
| 2 | **New user with invitation** | "Join a Space" card takes top priority before "Create your first Space" | Verified (`home_page_test.dart`) |
| 3 | **Space but no Worker** | Normal Home dashboard renders; no setup warning banner or Worker blocker | Verified (`home_page_test.dart`) |
| 4 | **Invitation received realtime** | Appears immediately in "For You" with Accept / Decline actions | Verified (`home_page_test.dart`) |
| 5 | **Invitation accepted** | Invitation item is removed from "For You" and joined Space appears in Continue Working / Spaces | Verified (`home_page_test.dart`) |
| 6 | **Thread needs input** | Appears in "For You" with direct "Review →" action link to thread conversation | Verified (`home_page_test.dart`) |
| 7 | **Work running** | "Running now" section appears with animated progress indicator, objective, task count, and "Open →" | Verified (`home_page_test.dart`) |
| 8 | **Work completes** | "Running now" card disappears; completion review item appears in "For You" with "Open →" | Verified (`home_page_test.dart`) |
| 9 | **Recent Thread** | Active unarchived threads render in "Continue working" with space name, title, collaborators, and snippet | Verified (`home_page_test.dart`) |
| 10 | **Archived Thread** | Archived threads (`archived: true`) and archived spaces are filtered out from "Continue working" | Verified (`home_page_test.dart`) |
| 11 | **Product update** | Published `AxProductUpdate` renders in "What's new in Syntila" and increments unread badge count | Verified (`home_page_test.dart`) |
| 12 | **Old/read update** | Read updates (`AxUserProductUpdateState.isSeen / isRead`) do not show unread badge count | Verified (`home_page_test.dart`) |
| 13 | **ChatGPT model added** | Relevant AI Update appears in "AI updates" when user has ChatGPT Worker configured | Verified (`home_page_test.dart`) |
| 14 | **Gemini update without access** | Gemini update is hidden when user does not have access to Gemini Worker | Verified (`home_page_test.dart`) |
| 15 | **Worker access revoked** | Related AI update disappears immediately when Worker access is revoked | Verified (`home_page_test.dart`) |
| 16 | **Empty optional section** | Optional sections ("For you", "Running now", "AI updates") are completely hidden when empty | Verified (`home_page_test.dart`) |
| 17 | **Offline** | Cached Home survives; displays connectivity indicator pill without replacing page content | Verified (`home_page_test.dart`) |
| 18 | **Space permission revoked** | Attention items, runs, and recent work tied to revoked spaces disappear immediately | Verified (`home_page_test.dart`) |
| 19 | **Realtime reconnect** | Replay/reconnect duplicate transport events are deduplicated by ID with no duplicate items | Verified (`home_page_test.dart`) |
| 20 | **Narrow / mobile layout** | Renders cleanly on mobile viewports (e.g. 360px x 640px) with single-column responsive stacking and zero overflow | Verified (`home_page_test.dart`) |

---

## Analytics & Product Discovery Telemetry (Phase 34)

Home is a **product-discovery surface**. It is instrumented lightly to measure discovery velocity and navigation effectiveness rather than passive vanity metrics like isolated "Home viewed" impressions.

### 1. Measured Interactions & Events

The following 6 core interaction paths are measured:

| Interaction Path | Telemetry Event Name | Event Payload Properties | Rationale |
|---|---|---|---|
| **Home → Continue Thread** | `home.continue_thread` | `spaceId`, `threadId`, `spaceName`, `threadTitle` | Measures how effectively Home accelerates return to ongoing collaborative work |
| **Home → Accept invitation** | `home.accept_invitation` | `invitationId`, `spaceId`, `role` | Measures successful onboarding and collaboration expansion |
| **Home → Resolve attention** | `home.resolve_attention` | `itemId`, `type`, `actionLabel`, `spaceId`, `threadId` | Measures triage efficiency for blocked runs, input requests, and worker issues |
| **Home → Open What's New** | `home.open_whats_new` | `updateId`, `unreadCount`, `source` | Measures feature awareness and changelog engagement |
| **Home → AI Update** | `home.open_ai_update` | `updateId`, `workerProfileId`, `provider`, `type` | Measures AI capability discovery and worker configuration velocity |
| **Home → Create Space** | `home.create_space` | `source` (`new_user_primary`, `new_user_secondary`, `home_cta`) | Measures space creation conversion from onboarding and home surfaces |

### 2. Implementation & Design Principles
- **Lightweight & Non-Blocking:** Telemetry recording via `AxHomeAnalytics` is fail-safe, non-blocking, and never interferes with UI responsiveness or error states.
- **Pluggable Sink (`AxHomeAnalytics.setSink`):** Telemetry sinks can be plugged in by client applications or tests to inspect and route events without coupling to third-party vendor SDKs.

---

## Obsolete Dashboard Removal & Clean-Room Architecture (Phase 35)

With the completion and verification of the V2 Home experience, all obsolete V1 dashboard artifacts have been excised:

- **Excised Legacy Widgets & Containers:**
  - `_HomeCard` & `_MetricCard` widget definitions.
  - Legacy metric counter cards: `Spaces`, `Workers`, `Ready Workers`.
  - Legacy plain `Recent Spaces` list.
  - Legacy `execution-capacity` subtitle.
  - Permanent `No active Runs` placeholder card.
  - Permanent `Nothing needs your attention` placeholder card.
  - Archived Spaces Home modal action (archived space management is now housed exclusively under Space settings/navigation).
  - Legacy Worker-first onboarding ("Connect a Worker", "No Worker connected").
- **No Feature Flags / Dead Paths:**
  - Zero legacy fallback flags or conditional dead-code paths remain.
  - Strict compile-time and runtime invariant tests assert the total absence of legacy cards across both established-user and new-user states.

### Compact-screen navigation

On compact screens, Home and `/spaces` show the full-page Spaces/Threads list.
Spaces expand in place and Threads open as full-screen detail pages. The HUD logo
returns to the list, preserving position and expansion. New Space is a HUD
action alongside Search, Notifications, and the application menu. The list HUD shows the account name as a link to the account page instead of
Spaces; the application menu has no Account item. The HUD has no avatar or
Back button.
Row action icons appear only for selected or hovered Spaces and Threads. Desktop
retains the Home dashboard and sidebar. Pending invitations remain accessible
from the list and Inbox.
