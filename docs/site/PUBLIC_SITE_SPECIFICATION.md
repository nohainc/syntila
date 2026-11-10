# Syntila Public Website

**Status:** Current public-site contract; **Canonical domain:** `https://conclaveax.com`

## Purpose

The public site explains Syntila and directs visitors to the authenticated
application. It does not implement application workflows or own user, Space,
Thread, Workspace, or Worker state.

| Domain | Responsibility | Authentication |
| --- | --- | --- |
| `conclaveax.com` | Public Astro website | None |
| `www.conclaveax.com` | Redirect to the canonical domain | None |
| `syntila.app` | Authenticated Syntila application | Better Auth |

The public site links to `https://syntila.app`. It does not proxy or
embed the application. Syntila Cloud provides application APIs, authentication,
authorization, and orchestration. Syntila Workspace is the local desktop
runtime that supervises provider CLI execution.

## Visitor outcomes

The site should help a visitor understand:

1. What Syntila does.
2. How Spaces, Threads, Syntila Cloud, and Syntila Workspace relate.
3. How local provider CLI execution and Tool Profiles fit into the system.
4. Where to start.

The primary call to action is **Open Syntila**. A secondary **See how it
works** action links to public explanatory content.

## Product explanation

Syntila is where people discuss work, direct Threads, and review
execution evidence. Syntila Cloud owns shared product state and authorization.
A Space may use a Workspace through an explicit Space-to-Workspace Grant.
Syntila Workspace runs locally and supervises the CLI Worker Engine, which
invokes a locally installed provider CLI using an approved Tool Profile.

```text
Syntila -> Syntila Cloud -> Space / Thread policy
                                      |
                             Space-to-Workspace Grant
                                      v
                           Syntila Workspace
                                      |
                         CLI Worker Engine + Profile
                                      |
                              Provider CLI
```

The site must describe visible execution, evidence, and user control without
promising that an AI result is correct. Logical Workers such as ChatGPT and
Gemini are product capabilities backed by local CLI integrations. Provider
authentication stays with the provider CLI on the user's machine; Syntila
does not store provider credentials in Cloud product tables.

## Navigation and legal routes

Keep navigation shallow. Product, How it works, Workers, Security, and Open
Syntila are suitable initial destinations. The footer may link to the
public source repository, Privacy, and Terms. Legal routes must contain the
current service notices before public account creation.

Pricing, a blog, and a separate documentation portal are optional and are not
required to explain the current product.

## Security claims

Public security content may explain these boundaries:

- Better Auth establishes the human application session.
- Syntila Cloud enforces Space, Workspace, Thread, and Profile policy.
- A Space can use a Workspace only through an explicit grant.
- Syntila Workspace supervises local provider processes and keeps provider
  credentials local.
- Tool Profiles are signed, bounded configuration interpreted by the generic
  CLI Worker Engine.

Avoid absolute claims such as “unhackable,” “zero risk,” or guaranteed model
correctness. Do not publish secrets, private Workspace details, or unsupported
availability and provider claims.

## Public terminology

Use **Syntila**, **Syntila Cloud**, **Syntila Workspace**, **Space**,
**Thread**, **Worker**, **CLI Worker Engine**, and **Tool Profile** for the
current product. Avoid retired product concepts and implementation names in
public copy. Provider names may appear when they match the current catalog and
trademark requirements.

## Explicit boundaries

The public site does not:

- implement login, discussion, Work, execution, or orchestration;
- show private Space, Workspace, or Worker data;
- install or register a Workspace;
- collect provider credentials or machine credentials;
- expose authenticated Cloud APIs as public website functionality.

## Implementation and accessibility

- Use Astro with static-first output and minimal client-side JavaScript.
- Support narrow, medium, and wide layouts, keyboard navigation, visible focus,
  reduced motion, and forced-colors/high-contrast preferences.
- Use semantic landmarks, one logical `h1`, ordered headings, useful image
  alternatives, and accessible controls.
- Keep architecture diagrams understandable through visible text labels.
- Provide canonical metadata, social preview metadata, `sitemap.xml`,
  `robots.txt`, favicon, and a web manifest.
- Keep application links as ordinary HTTPS links that do not depend on shared
  client state.

The site is performance-budgeted for static HTML, no third-party JavaScript,
system fonts, and small generated assets. CI checks generated HTML, CSS,
scripts, routes, accessibility structure, security headers, analytics privacy,
responsive behavior, and performance budgets. A manual browser review remains
part of launch validation.

## Analytics and security headers

Marketing analytics are separate from Syntila Cloud telemetry. Any enabled
analytics sends only aggregate event name, public path, and timestamp. When the
configured endpoint is absent, no analytics requests are sent. Do not send
cookies, user identifiers, Space or Workspace identifiers, credentials, or
application content.

The public Worker uses a self-only Content Security Policy, denies framing,
sets strict transport/referrer/permissions policies, and strips `Set-Cookie`
from asset responses. Analytics endpoints must be same-origin.

## Visual system

Use the established Syntila brand system (`docs/design/SYNTILA_BRAND_SYSTEM.md`): dark slate canvas (`#121217`), elevated layered surfaces (`#18181f`, `#20202a`), high-contrast off-white ink text (`#f3f3f7`), Precision Indigo (`#6366f1`) accents and focus rings, crisp subtle borders, and compact system monospace details. Prefer existing tokens and Astro components over one-off section styles. Do not rely on decorative gradients, radial glows, robot imagery, or animation to explain the product.

## Acceptance checklist

An implementation is conformant when a visitor can, without signing in:

- distinguish the public site from `syntila.app`;
- explain the Space/Thread to Workspace execution path;
- understand that provider execution uses local CLI software;
- find the primary application action and public product explanations;
- use the site with a keyboard and on narrow screens;
- find no stale product model or unsupported product promise in generated HTML.

The [public site release gate](PUBLIC_SITE_RELEASE_GATE.md) defines automated
checks and the human comprehension review.
