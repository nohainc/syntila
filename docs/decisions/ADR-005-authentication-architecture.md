# ADR-005: Better Auth for human authentication

**Status:** Accepted; **Date:** 2026-09-23

## Context

Syntila needs one human authentication boundary across the web application and
Cloud APIs. Authentication establishes who is acting; Syntila's domain policy
decides which Spaces, Workers, Threads, and Profiles that person may
use.

Human sessions, Worker credentials, and provider CLI credentials
serve different purposes and must remain separate.

## Decision

Use Better Auth as the human authentication engine. Mount it in Syntila Cloud
at `/api/auth/*` and persist authentication records in D1 using its supported
D1 integration. The initial sign-in methods are email/password, GitHub, and
Google.

The browser uses same-origin Secure, HttpOnly session cookies. Application code
does not read session tokens into local storage or manufacture session
cookies. Cloud maps the authenticated identity to a Syntila User and remains
the authority for authorization.

Syntila authorization is based on current domain rules: Space membership
and roles, Worker ownership and sharing,
Thread policy, step-up authentication, and Profile administration and
release policy. Better Auth Organizations, if enabled for an identity-provider
integration, do not define Syntila resource access.

Connect uses a Worker-scoped credential and session independently of a human
management session, as detailed in ADR-034. Provider authentication
is performed by locally installed provider CLI software. Provider credentials
remain local and are not stored as Cloud product records.

Cloudflare Access may protect staging or internal infrastructure. Application
authentication and authorization do not depend on Access identity headers.

## Required boundary

Requests acting for a person use the Better Auth session and resolve to a
Syntila User before authorization. Runtime and CI paths use explicitly scoped
credentials and are not treated as human sessions. Credentials are not
interchangeable. Backend bearer tokens accept human and internal principals;
Worker sessions authenticate through their dedicated gateway boundary.

Never store API keys or provider credentials in plaintext application tables.

## Consequences

- Human sign-in has one documented owner.
- Syntila retains precise control over resource authorization.
- Worker identity and provider CLI identity cannot be confused with
  the human session.
- Session cookies, CSRF, redirect, identity mapping, and same-origin behavior
  require deployment validation.
- Better Auth schema and lifecycle are part of Cloud deployment and recovery.

## Revisit conditions

Reconsider the identity provider or session storage only if product requirements
need a new sign-in method, federation protocol, or a measured D1 limitation.
Do not replace Syntila authorization with identity-provider organization
membership.
