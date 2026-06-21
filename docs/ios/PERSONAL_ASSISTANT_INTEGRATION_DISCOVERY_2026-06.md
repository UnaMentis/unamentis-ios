# Personal Assistant Integration: iOS Discovery

**Date:** 2026-06-04
**Status:** Discovery only. This document is about understanding what is and is not possible. It is not an architecture or a build plan.
**Target OS:** iOS 26 (the WWDC 2025 cycle, currently shipping). Notes flag iOS 17 and iOS 18 baselines where relevant.
**Author:** Research synthesis from five parallel investigations (codebase, email/messaging, calendar/tasks/ecosystem, health/notifications, on-device LLM/privacy).
**Updated 2026-06-06:** Added Addendum A, a service-specific deep dive on Gmail (the chosen email source), Slack, and Discord.

---

## 1. Purpose and scope

We want to understand what it would take to build a genuine on-device personal assistant inside the UnaMentis Assistant section. The assistant should be able to help the user with their email, their messages, their calendar, their tasks, their medications and health, and it should be able to use the full notification system to get the user's attention and convey information. The strong product requirement is privacy: sensitive personal-data tasks should run on a trusted on-device model by default, and any use of a remote server or cloud foundation-model API for that sensitive data must sit behind a hard, multi-step, fully informed consent gate.

This document maps the integration surface that modern iOS exposes to a third-party App Store app. For each capability it answers three questions: can we do it, what is involved, and where is the wall. It deliberately stops short of designing a solution.

The scope is on-device first, as requested. Where a capability is impossible on-device and only achievable through an account or cloud integration (email is the prime example), that fact is called out as the central finding for that area rather than glossed over.

### Classification legend

Every capability below is tagged with one of:

- **[SUPPORTED]** Public API, works on-device, ships today with no special Apple approval.
- **[CONSTRAINED]** Works, but gated by a permission model, an account/cloud dependency, or a meaningful functional limit.
- **[APPLE-APPROVAL]** Requires an entitlement that Apple must individually grant after a review.
- **[BLOCKED]** Not available to third-party apps on any current iOS version.

---

## 2. The five findings that shape everything

1. **Email and messaging are the hard walls.** No public API on any iOS version lets a third-party app read Apple Mail or read iMessage/SMS history. Reading email is only possible by integrating directly with a provider (Gmail, Microsoft Graph, or raw IMAP) through OAuth, which means the data path and credentials become our responsibility, not Apple's. Reading messages is effectively impossible by any sanctioned route. iOS 26 and Apple Intelligence do not change this.

2. **Calendar, Reminders, and Health (including medications, new in iOS 26) are genuinely open.** EventKit gives full on-device read/write to calendar events and the system Reminders store. As of iOS 26 there is a brand-new public HealthKit Medications API that lets an app read the user's real medication list, schedule, and adherence history with per-medication consent. These are the strongest integration surfaces available to us.

3. **The notification system is rich and can be loud, but the loudest tiers are gated.** Time-Sensitive notifications break through Focus and Do Not Disturb with a self-serve entitlement. Critical Alerts, which bypass even the silent switch, require a special Apple-granted entitlement justified by a clinical or safety risk. Live Activities, the Dynamic Island, communication-style notifications, custom sounds, and spoken "Announce Notifications" round out the toolkit.

4. **Apple ships a free, on-device LLM we can use: the Foundation Models framework (iOS 26).** It runs on-device only, never routes to the cloud, supports tool-calling and constrained structured output, and needs no entitlement. Its dominant limitation is a 4,096-token context window. Our existing MLX-Swift small-model path remains valuable for longer context and for devices without Apple Intelligence.

5. **There is no OS-level way to prove data never leaves the device.** "On-device only" is an architectural promise we make and must substantiate, not something iOS attests for us. iOS has no self-imposed "no network" entitlement. Apple's App Review Guideline 5.1.2(i), updated November 2025, now requires explicit in-app, per-data-type consent before sharing personal data with any third-party AI, which makes our hard-gate requirement an App Store requirement, not just a product preference.

---

## 3. Master capability matrix

| Domain | Capability | Verdict | iOS / framework | Key gate |
|---|---|---|---|---|
| **Email** | Read Apple Mail / iCloud inbox | [BLOCKED] | all incl. 26 | No API exists |
| Email | Compose and send (user taps Send) | [SUPPORTED] | iOS 3+, MessageUI | Requires Mail.app configured |
| Email | Read via Gmail / Graph / IMAP | [CONSTRAINED] | OS-independent | OAuth + provider security review |
| **Messaging** | Read iMessage / SMS history | [BLOCKED] | all incl. 26 | No API exists |
| Messaging | Compose and send SMS/iMessage (user taps Send) | [SUPPORTED] | iOS 4+, MessageUI | User confirmation required |
| Messaging | Read/send via SiriKit for the app's OWN service | [CONSTRAINED] | SiriKit | Only the app's own message store |
| Messaging | Read third-party messengers (WhatsApp, Signal, etc.) | [BLOCKED] | all | Personal accounts have no API |
| Messaging | Read other apps' notifications | [BLOCKED] | all | Extensions see own app only |
| **Gmail** (svc, see A1) | Read + triage mailbox, on-device REST | [CONSTRAINED] | OAuth restricted scope | Verification + likely CASA |
| Gmail (svc) | Send / draft only | [CONSTRAINED] | OAuth `gmail.send` | Verification, no CASA |
| Gmail (svc) | Real-time push of new mail | [CONSTRAINED] | `users.watch` + Pub/Sub | Requires a backend server |
| **Slack** (svc, see A2) | Read user DMs/channels, no backend | [BLOCKED] in practice | user token + polling | 2025 limit: 1 req/min, 15 msgs |
| Slack (svc) | Send as the user | [SUPPORTED] | user token `chat:write` | Device-direct, per-workspace auth |
| Slack (svc) | Real-time read at normal rate limits | [CONSTRAINED] | Events API + Marketplace listing | Server + Slack review |
| **Discord** (svc, see A3) | Read user's messages/DMs, act as user | [BLOCKED] | none (self-bot ToS ban) | Bannable; bot-only model |
| Discord (svc) | User-invited bot in chosen channels | [CONSTRAINED] | bot + Message Content intent | Requires server; not the user |
| **Calendar** | Full CRUD on events | [SUPPORTED] | EventKit, iOS 17 perms | Full-access prompt |
| Calendar | Confirmation-gated event creation, no prompt | [SUPPORTED] | EventKitUI iOS 17+ | User taps Add |
| **Tasks** | Full CRUD on system Reminders | [SUPPORTED] | EventKit, iOS 17 perms | Full-access prompt |
| Tasks | Integrate Things/Todoist/OmniFocus | [CONSTRAINED] | App Intents / URL schemes | Per-app, create-mostly |
| **Health** | Read steps, vitals, workouts, etc. | [SUPPORTED] | HealthKit | Per-type read auth |
| Health | Read user's medication list + adherence | [SUPPORTED] | HealthKit iOS 26 (NEW) | Per-medication auth |
| Health | Write medications / log a dose to Health | [BLOCKED] | iOS 26 | No public write path |
| Health | Read clinical records (FHIR) | [CONSTRAINED] | HealthKit | Provider-connected, read-only |
| **Notifications** | Local scheduled notifications | [SUPPORTED] | UserNotifications | 64 pending-per-app limit |
| Notifications | Time-Sensitive (breaks Focus/DND) | [CONSTRAINED] | UserNotifications | Self-serve entitlement |
| Notifications | Critical Alerts (breaks silent switch) | [APPLE-APPROVAL] | UserNotifications | Apple must grant entitlement |
| Notifications | Rich UI, actions, text input | [SUPPORTED] | Notification extensions | None |
| Notifications | Live Activities + Dynamic Island | [SUPPORTED] | ActivityKit iOS 16.1+ | Display surface, not alerting |
| Notifications | Spoken "Announce Notifications" | [SUPPORTED] | `.announcement` option | User setting, cannot force on |
| **Ecosystem** | Expose our actions to Siri/Shortcuts/Spotlight | [SUPPORTED] | App Intents iOS 16+ | None |
| Ecosystem | Apple Intelligence drives our calendar/tasks via schema | [BLOCKED] | iOS 18/26 | No calendar/tasks schema exists |
| Ecosystem | New personal-context Siri runs our App Intents | [CONSTRAINED] | future iOS | Delayed by Apple to ~2026 |
| **On-device LLM** | Apple Foundation Models (on-device) | [SUPPORTED] | iOS 26 | 4,096-token context |
| On-device LLM | Our own MLX/llama.cpp/MLC model | [SUPPORTED] | any | We own memory/tooling |
| **Privacy** | OS-proven "data never leaves device" | [BLOCKED] | all | Developer-asserted only |

---

## 4. Where the app stands today

Grounding the research in the current codebase, so the gap is clear.

**The Assistant section already exists.** [AssistantTabView.swift](UnaMentis/UI/Assistant/AssistantTabView.swift) is a container with three segments: To-Do, Reading List, and Review. There is no conversational personal-assistant surface yet. The voice conversation machinery lives in [SessionView.swift](UnaMentis/UI/Session/SessionView.swift) and its inline `SessionViewModel`, orchestrated by the actor in [SessionManager.swift](UnaMentis/Core/Session/SessionManager.swift). A personal assistant would most naturally appear as a new segment or first-class item here and would reuse the existing voice session UI.

**App Intents are already in place.** The app ships four intents in [UnaMentis/Intents/](UnaMentis/Intents/): StartConversation, StartLesson, ResumeLearning, ShowProgress, registered through [AppShortcutsProvider.swift](UnaMentis/Intents/AppShortcutsProvider.swift), with a `unamentis://` deep-link scheme. This is the modern ecosystem entry point and it is the foundation we would extend.

**On-device LLM is scaffolded but not wired.** The protocol is [LLMService.swift](UnaMentis/Services/Protocols/LLMService.swift). Implementations exist for Anthropic, OpenAI, self-hosted, and a mock, plus an [OnDeviceLLMService.swift](UnaMentis/Services/LLM/OnDeviceLLMService.swift) that is currently marked incompatible and excluded in [project.yml](project.yml). The audit recommendation (Qwen3-1.7B via MLX-Swift) is documented but the MLX-Swift integration is not yet started. There is a settings surface, [OnDeviceLLMSettingsView.swift](UnaMentis/UI/Settings/OnDeviceLLMSettingsView.swift), for model download. On-device TTS (Kyutai Pocket) is already integrated, and on-device STT (FluidAudio Parakeet) is gated behind a compile flag.

**The relevant permissions are not declared yet.** [UnaMentis.entitlements](UnaMentis/UnaMentis.entitlements) currently declares only app-sandbox, audio-input, and network-client. [Info.plist](UnaMentis/Info.plist) declares usage strings for microphone, speech recognition, and local network, plus the `audio` background mode. There is no EventKit, HealthKit, Contacts, MessageUI, UserNotifications, or ActivityKit usage anywhere in the app today. Every integration in this document is net-new work.

**There is no privacy consent flow yet.** There is no "on-device only" mode, no per-data-type toggle, and no consent UX. The existing on-device LLM settings view is the closest analogue and a plausible seed.

The practical takeaway: the assistant shell, the App Intents foundation, and the on-device model direction already exist. Calendar, Reminders, Health, notifications, and the privacy gate are all greenfield.

---

## 5. Email

**The headline: there is no way to read Apple Mail from iOS. Reading email at all means integrating with a provider account directly, which moves the data path and the trust burden onto us.**

### What is blocked

Reading the user's Apple Mail or iCloud Mail inbox is **[BLOCKED]** on every iOS version including 26. Apple provides no email API for iCloud Mail: no REST interface, no SDK, no developer portal. The app sandbox prevents reading Mail.app's data store, and Mail content is not vended through any cross-app mechanism. The macOS MailKit framework (mail extensions, content blockers, action handlers) is **macOS-only** and has no iOS equivalent, and even on macOS it cannot read arbitrary mailbox content. iOS 26 and Apple Intelligence do not open this. The new App Intents surfaces are outbound only: our app can expose its own content to the system, it cannot pull Mail content in.

### What is supported

Composing and sending email is **[SUPPORTED]** via `MFMailComposeViewController` (MessageUI, iOS 3+). The app presents a system compose sheet pre-filled with recipients, subject, body, and attachments. The user stays in our app after sending. The hard limits: the user must tap Send (no silent send, this is an enforced privacy boundary), Apple Mail must be configured (call `canSendMail()` first), and it does not work when running as an iOS app on Apple silicon Macs. No entitlement, no review friction.

### What is possible with constraints

Actually reading email is **[CONSTRAINED]**: the only route is per-provider, per-account OAuth integration that bypasses Apple's apps entirely.

- **Gmail API.** Reading message bodies uses Google's *restricted scopes*. Any production app beyond roughly 100 users must pass Google's OAuth verification plus an annual CASA (Cloud Application Security Assessment) by a Google-empanelled assessor, which can cost hundreds to thousands of dollars per year and must be renewed. One genuinely open question: a purely on-device client that talks device-to-Gmail with no backend server may face a lighter path, because Google's stricter rules key on data routed "from or through a third-party server." This boundary is ambiguous in 2026 and needs direct confirmation against Google's live User Data Policy. **Gmail is our chosen email source and is treated in full in [Addendum A1](#a1-gmail-as-the-email-source).**
- **Microsoft Graph (Outlook).** Use MSAL for iOS with the `Mail.Read` delegated permission. For consumer accounts, on-device user consent generally suffices and admin consent is usually not required. Tokens are cached on-device with silent refresh.
- **Generic IMAP/SMTP.** Fully possible with the user's credentials or an app-specific password (this includes iCloud Mail via IMAP, ironically, just not via any Apple framework). No entitlement. This is the most on-device-friendly route because we implement IMAP directly and the data can stay local, but the UX is poor (manual app-specific-password creation) and we own all the sync, MIME parsing, and auth infrastructure.

**The privacy consequence.** Because there is no Apple Mail API, any email feature means we hold the OAuth tokens and the message data. Those tokens belong in Keychain backed by the Secure Enclave. The data-locality promise becomes entirely ours to keep. App Review will scrutinize this: reading mailbox contents requires accurate Privacy Nutrition Label disclosure, and harvesting or building a contact graph from mail content risks rejection under Guideline 5.1.

---

## 6. Messaging

**The headline: messaging is effectively read-blocked. We can help the user compose a message, and we can route sends to our own message service, but we cannot read their iMessage, SMS, or third-party chats by any sanctioned means.**

### What is blocked

- Reading iMessage / SMS / MMS history is **[BLOCKED]**, definitively, on all iOS versions. No API exposes the Messages content store. Apps cannot read, monitor, or intercept messages. The one narrow non-content touch is SMS one-time-code autofill into a `.oneTimeCode` field, where iOS extracts only the code and the app never sees the message.
- iMessage app extensions (the Messages framework) run inside the Messages app and can insert content into the *current* conversation, but **[BLOCKED]** from reading history. They see only the single tapped message and opaque, device-specific participant UUIDs, not names or numbers.
- Reading third-party messengers (WhatsApp, Signal, Telegram, Messenger) on a personal account is **[BLOCKED]**. The Business and Bot platforms some of them offer are cloud-hosted business integrations, not personal-account access. The EU's DMA interoperability for WhatsApp is opt-in, region-gated, and not a general assistant API.
- Reading *other apps'* notifications as a signal is **[BLOCKED]**. Notification Service and Content extensions only ever see our own app's notifications. iOS has no equivalent of Android's `NotificationListenerService`. We cannot harvest "new message from Mom" banners from other apps.

### What is supported

Composing and sending SMS/iMessage is **[SUPPORTED]** via `MFMessageComposeViewController` (MessageUI, iOS 4+). Same model as email compose: a system sheet, pre-filled, and the user must tap Send. Call `canSendText()` first.

### What is possible with constraints

SiriKit Messaging intents (`INSendMessageIntent`, `INSearchForMessagesIntent`) are **[CONSTRAINED]**: they let a messaging app register as a provider so Siri and Shortcuts can route "send a message" or "search my messages" to *that app's own service*. The app returns `INMessage` objects from its own store. This does not read Apple's iMessage or any other app's messages. It is only useful if UnaMentis itself becomes a messaging service, which is not the use case here. Note the Messaging domain is one of the few SiriKit domains not deprecated, so for a genuine messaging provider it remains the path.

**The product consequence.** A "help me with my messages" assistant on iOS can draft a message and hand it to the system sheet for the user to send. It cannot read incoming messages, summarize a thread, or triage an inbox. This is a hard limit to set expectations around early.

---

## 7. Calendar and tasks

**The headline: this is the strongest integration surface available. EventKit gives full on-device read/write to both calendar events and the system Reminders store. The only friction is the iOS 17 permission split.**

### Calendar events: [SUPPORTED]

EventKit's `EKEventStore` provides full CRUD on events across all the user's calendars: create, read, update, delete, recurring events (`EKRecurrenceRule`), alarms (`EKAlarm`), span control for recurrence edits, multiple calendars and sources. All on-device, no server, no special entitlement beyond Info.plist purpose strings.

The important detail is the **iOS 17 permission split**. A single calendars permission became two distinct levels:

| | Full access | Write-only access |
|---|---|---|
| Request | `requestFullAccessToEvents()` | `requestWriteOnlyAccessToEvents()` |
| Status | `.fullAccess` | `.writeOnly` |
| Info.plist key | `NSCalendarsFullAccessUsageDescription` | `NSCalendarsWriteOnlyAccessUsageDescription` |
| Can read events? | Yes | No, not even events it created |
| Can list calendars? | Yes | No |
| Can create events? | Yes | Yes |

The trap: calling the legacy `requestAccess(to: .event)` on iOS 17+ now prompts for *write-only* only. An assistant that reasons over the user's schedule needs **full** access, so plan the UX around a full-access prompt. A write-only app is implicitly upgraded if it later calls a read API (the user gets an upgrade prompt).

A standout capability for an assistant: **`EKEventEditViewController` (EventKitUI) on iOS 17+ runs out-of-process and can be presented with no calendar permission at all**. The user's tap to confirm *is* the consent. This is the ideal "confirm before I add this" pattern, no upfront permission wall.

### Tasks via Reminders: [SUPPORTED]

EventKit Reminders (`EKReminder`) is the system to-do store, the same data Siri and Reminders.app use. Full CRUD, due dates, priorities, multiple lists, location-based alarms. iOS 17 adds `requestFullAccessToReminders()` with `NSRemindersFullAccessUsageDescription` (there is no write-only tier for reminders). For a tasks assistant built on Apple's own task system, this is the integration path, and it is clean.

### Third-party task apps: [CONSTRAINED]

Things, Todoist, and OmniFocus have no private API into their databases. Integration is per-app, in rough order of robustness: their App Intents donated to Shortcuts (cleanest, structured), x-callback-url / custom URL schemes (mature for create actions, limited for reading back), or cloud REST APIs (full but off-device, breaks the privacy posture). Treat these as best-effort, app-specific adapters. Prefer App Intents where present, fall back to URL schemes for create.

---

## 8. Health and medications

**The headline: as of iOS 26 there is a brand-new public HealthKit Medications API. We can read the user's real medication list, schedule, and adherence history with per-medication consent. We cannot write medications or log doses back to Health, so Health is a read source and our app owns scheduling.**

### HealthKit overall: [SUPPORTED]

`HKHealthStore`, with the HealthKit capability (`com.apple.developer.healthkit` entitlement) and two usage strings, `NSHealthShareUsageDescription` (read) and `NSHealthUpdateUsageDescription` (write). Permission is per-data-type, separately for read and write.

A privacy rule that shapes design: **an app can never tell whether the user denied read access**. A denied type simply appears as having no data. Our assistant must treat "empty" and "denied" identically and degrade gracefully. HealthKit data is stored encrypted on-device and is not synced through iCloud in the general case, which supports an on-device privacy claim. One operational limit: the app cannot *read* HealthKit data while the device is locked (writes are buffered). Background reaction to new samples uses `HKObserverQuery` plus `enableBackgroundDelivery`, which needs the HealthKit Background Delivery capability and effectively processes when the device is unlocked.

### Medications, new in iOS 26: [SUPPORTED] for read, [BLOCKED] for write

This is the significant change. iOS 16 introduced a Medications feature in the Health app with no third-party API. WWDC 2025 shipped the public HealthKit Medications API (iOS 26 cycle).

| Capability | Verdict | API |
|---|---|---|
| Read medication list (name, form, strength, nickname, archived, has-schedule, RxNorm codes) | [SUPPORTED] read | `HKUserAnnotatedMedication` → `HKMedicationConcept` |
| Read dose / adherence events (taken / skipped / snoozed, scheduled vs actual, scheduled date) | [SUPPORTED] read | `HKMedicationDoseEvent` |
| Query medications and dose events over time | [SUPPORTED] | `HKUserAnnotatedMedicationQueryDescriptor`, `HKSampleQuery` / `HKAnchoredObjectQuery` |
| Create a medication | [BLOCKED] | Health app only |
| Log a dose back to Health | [BLOCKED] | No accessible public initializer |

Authorization is special: **per-object, not per-type**. The app calls `requestPerObjectReadAuthorization` with `HKUserAnnotatedMedicationType`, and the user grants or denies *individual medications* in the Health UI. Granting a medication automatically grants its dose events. When the user later adds a medication, Health prompts them to extend access.

**Version flag to verify in-IDE:** this is confirmed as the iOS 26 cycle (WWDC 2025), but the exact `@available(iOS 26.x, *)` badge should be confirmed in the Xcode SDK headers before committing a deployment target, because Apple's doc pages render client-side and did not expose the literal badge to research.

### Clinical records (FHIR): [CONSTRAINED]

`HKClinicalRecord` exposes provider-connected records as FHIR resources (medications, conditions, labs, immunizations). Read-only, requires the user to have connected a participating provider, needs `NSHealthClinicalHealthRecordsShareUsageDescription`, and draws stricter App Review. A clinical `medicationRecord` is a prescription-from-provider view, distinct from the user-curated medication list above. The user-annotated medications surface is more directly useful for a reminder assistant.

### The realistic medication-reminder model

Because we cannot write a schedule or log adherence into Health, the assistant owns scheduling: optionally read the user's meds and schedule from the iOS 26 API to seed our own model and to see what they already logged, then schedule reminders ourselves as local notifications (Time-Sensitive, escalating to Critical only with Apple approval), and track taken/skipped in our own store. Health is the read-side source of truth, not the scheduler.

An App Store note: Guideline 5.1.3 forbids using health data for advertising or data-mining and forbids storing personal health information in iCloud.

---

## 9. Notifications: every bell and whistle

**The headline: the toolkit is rich. Time-Sensitive notifications break through Focus with a self-serve entitlement and are the right default for reminders. Critical Alerts bypass even the silent switch but need Apple's individual approval. Spoken announcements make the whole thing work hands-free.**

The app uses no notifications today, so all of this is net-new.

### Foundations: [SUPPORTED]

Local notifications via `UNUserNotificationCenter`, scheduled with `UNCalendarNotificationTrigger` (specific or repeating times, the right tool for medication times), `UNTimeIntervalNotificationTrigger`, or `UNLocationNotificationTrigger`. A real constraint: **iOS keeps only the soonest-firing 64 pending requests per app** and silently discards the rest, so prefer repeating triggers (each counts as one) over enumerating many future instances. Authorization can be `provisional` (delivered quietly with no prompt, good for a hands-free first run so the user is not blocked by a permission wall) and later promoted by the user.

Remote push (APNs) is **[SUPPORTED]** but requires a server. For a purely on-device assistant, local notifications cover scheduled reminders and a server may be unnecessary. Push is only needed for server-driven content or push-to-start Live Activities.

### Interruption levels: the part that matters most

`UNNotificationInterruptionLevel` has four values:

- **`.passive`** and **`.active`** (default): **[SUPPORTED]**, no entitlement. Both are suppressed by Focus and Do Not Disturb.
- **`.timeSensitive`**: **[CONSTRAINED]** by a self-serve entitlement (`com.apple.developer.usernotifications.time-sensitive`), no Apple approval needed. Delivered immediately, surfaced above other notifications, **breaks through Focus and Do Not Disturb** (subject to the user's per-app Focus settings), lights the screen, plays sound. Does not bypass the hardware silent switch. **This is the recommended default for medication and time-critical reminders.**
- **`.critical`** (Critical Alerts): **[APPLE-APPROVAL]**. The entitlement `com.apple.developer.usernotifications.critical-alerts` must be requested and justified to Apple through a dedicated form, reviewed manually over days to weeks. It **ignores the ringer/mute switch and Focus/DND** and always plays a sound even when silenced. Apple limits eligibility to health and safety cases where a missed alert is a clinical or life-safety risk, and explicitly lists medication apps "where a missed alert is a clinical risk" as eligible. A medication-adherence assistant has a plausible but not guaranteed case. Design so the app still works on Time-Sensitive if Apple declines.

Focus and silent-mode summary: passive/active are silenced by Focus; Time-Sensitive breaks Focus if the user permits it per-app but obeys the silent switch; Critical breaks everything.

### Rich, interactive, and persistent surfaces: [SUPPORTED]

- **Rich notifications:** image/audio/video attachments, Notification Service Extension (mutate an incoming push before display), Notification Content Extension (fully custom in-notification SwiftUI, for example a "Mark as taken / Snooze 10 min" medication card), action buttons (`UNNotificationAction`), and inline text input (`UNTextInputNotificationAction`).
- **Communication notifications:** **[CONSTRAINED]**. Built on a donated `INSendMessageIntent`, they show a sender avatar and get Focus "from people" allowances and announcement priority. Intended for genuine person-to-person communication; Apple may reject using this to dress up a non-communication alert, so only use it if the reminder is genuinely framed as a message from a persona the user set up.
- **Live Activities and Dynamic Island (ActivityKit, iOS 16.1+):** a persistent Lock Screen and Dynamic Island surface (the Dynamic Island needs iPhone 14 Pro or newer). Active up to ~8 hours. Updated locally or via push, with push-to-start since iOS 17.2 and broadcast push added in iOS 26. This is a *display* surface ("next dose in 25 min"), not an alerting one. Pair it with a Time-Sensitive notification for the actual nudge.

### Sounds, haptics, and the hands-free angle

- Custom notification sounds are **[SUPPORTED]** (`UNNotificationSound(named:)`, ~30s, aiff/caf/wav). Critical-alert sounds that bypass the silent switch (`defaultCriticalSound`) only work with the Critical Alerts entitlement.
- There is **no public API to specify a custom haptic pattern on a delivered notification**. Notification haptics are system-driven by interruption level. Custom CoreHaptics only plays while the app is foregrounded. So attention comes from level and sound, not bespoke notification haptics.
- **Announce Notifications** is the single best hands-free lever, and it is directly relevant to this app's VoiceOver-first design. Siri speaks incoming notifications into AirPods, other supported headphones, the iPhone speaker, and CarPlay, and lets the user reply or acknowledge by voice or head gesture. The app opts in with the `.announcement` authorization option, and communication-style notifications are prioritized for announcement. A Time-Sensitive, announcement-enabled reminder gets spoken into the user's ears and can be acknowledged without touching the phone. It is a user setting we cannot force on, so onboarding should guide the user to enable it.

VoiceOver reads delivered banners aloud automatically, so clear front-loaded titles, bodies, and action labels matter.

---

## 10. Ecosystem integration: App Intents, Siri, Shortcuts, Spotlight

**The headline: we can expose our own actions to Siri, Shortcuts, Spotlight, the Action Button, and widgets today through App Intents, which the app already uses. We cannot have Apple Intelligence drive a calendar or tasks experience through a typed schema, because no such schema exists, and the deep personal-context Siri that would autonomously run our intents is delayed.**

### What is supported today

App Intents (iOS 16+) is the modern foundation, and the app already ships four of them. It lets us expose `AppIntent` actions to Siri, Shortcuts, Spotlight, the Action Button, Control Center, widgets, and Apple Intelligence, with no entitlement and no usage string. `AppShortcutsProvider` phrases work the moment the app is installed, with no user setup. iOS 26 adds Interactive Snippets (live SwiftUI in a result with buttons that fire other intents, ideal for "confirm before committing"), Visual Intelligence participation, Spotlight as a new App Intents client (our actions and indexed entities can run directly in Spotlight), plus `PredictableIntent`, `UndoableIntent`, and App Intents in Swift packages.

Core Spotlight indexing is **[SUPPORTED]**: index our content as `CSSearchableItem` into the private on-device index. iOS 18 added semantic (meaning-based) search over indexed items, though beta reports suggest semantic ranking is still maturing, so test on-device.

Inter-app mechanisms under the sandbox are **[SUPPORTED]** with the obvious limits: custom URL schemes, Universal Links, x-callback-url, the Share Sheet (send out via `UIActivityViewController`, receive via a Share Extension), the Shortcuts app with Personal Automations, and document/file pickers. Everything cross-app is either user-initiated, declared, or mediated by Shortcuts. There is no silent access to another app's private data.

Focus filters (`SetFocusFilterIntent`, iOS 16) let our app **react** to the active Focus changing (show different content in Work vs Personal). We receive only our own filter config; we cannot read the global current Focus or other apps' filters. `INFocusStatusCenter` (user-permissioned) tells us only whether the user is in *a* Focus.

### What is blocked or delayed

- **No Calendar, Reminders, or Tasks assistant-schema domain exists.** Apple's App Intent assistant schemas (iOS 18, expanded in 26) cover Mail, Photos, Books, Browser, Files, Journaling, document apps, Camera, System/Search, Whiteboard, and Visual Intelligence, but **not** calendaring or tasks. So Apple Intelligence cannot drive a calendar or tasks feature through a typed schema. We fall back to plain custom `AppIntent`s and `AppShortcuts`, which work but are not schema-typed.
- **The deep "new Siri" (personal context, onscreen awareness, autonomously running third-party App Intents) is not live.** Apple's own docs state these features are in development for a future update, publicly slipped toward 2026. We can and should build App Intents now, but we cannot rely on Siri executing them via personal context today, and we should not promise Siri-driven behavior in a beta shipping now.
- The old SiriKit Lists/Notes domain, the closest legacy thing to a tasks intent, is deprecated. Use App Intents plus EventKit instead.
- An app cannot become *the* system assistant, replace Siri, or globally intercept the Action Button beyond its own intents. The sandbox holds.

---

## 11. The on-device LLM, and the privacy gate

This is the heart of the product's privacy requirement, so it gets the most careful treatment.

### 11.1 On-device model options

**Apple Foundation Models framework (iOS 26): [SUPPORTED], and the most important option.** It is the only on-device LLM Apple ships to third parties that is guaranteed never to leave the device, and it is free with no entitlement.

| Attribute | Fact |
|---|---|
| Availability | iOS 26 line, on Apple Intelligence-capable devices (iPhone 15 Pro / 16 / 17 and later) |
| Model | ~3B parameters, on-device, mixed 2-bit/4-bit (~3.7 bits per weight) |
| Speed | ~0.6 ms per token to first token, ~30 tokens/sec |
| **Context window** | **4,096 tokens total, input plus output** |
| Cloud routing | None. `SystemLanguageModel` is on-device only, with no API to reach Apple's server model |
| Cost | Free, offline-capable |
| Tool calling | Fully supported via a `Tool` protocol: declare a tool with a `@Generable` arguments struct and an async `call`; the model decides when to invoke; tools can run multiple times and in parallel |
| Structured output | `@Generable` + `@Guide` with constrained decoding, so the model can only emit tokens valid for the schema |

The dominant limitation is the **4,096-token window**. A long email thread plus a tool schema plus history overflows quickly; the framework throws `.exceededContextWindowSize`. iOS 26.4 added `contextSize` and `tokenCount(for:)` for dynamic budgeting. A 3B 2-bit model is also weak at math, broad world knowledge, and long-form reasoning, and is gated on the user having Apple Intelligence enabled, so we must handle the unavailable case.

**Our own model (MLX-Swift, the path the repo already chose): [SUPPORTED].** The project already targets Qwen3-1.7B via MLX-Swift. The advantages over Apple's framework: we control the model, we can use a much larger context window (MLC can reach 64K to 128K), we control the tool-calling format, and we are not gated on Apple Intelligence availability. The costs: we own model packaging, the iPhone memory ceiling (a ~1.5 to 1.7B 4-bit model is the safe universal choice; pushing larger needs the `increased-memory-limit` entitlement, which Apple must approve and which iOS can still jetsam under pressure), thermal/battery management (short bursts, not continuous inference), and our own constrained decoding for structured output.

**Can a small on-device model handle most assistant tasks? Mostly yes, with a reliability tail that needs care.** A ~1.5 to 3B model handles intent routing, single-document entity and event extraction, bounded summarization, and short drafting well, especially with constrained decoding. Where it falls short: tool/function-calling *semantic* reliability (constrained decoding fixes the format, not choosing the right tool with the right arguments; 3B-class models have documented low reliable-structured-output rates), long-context synthesis beyond the window, and multi-step planning or deep reasoning. The design implication for discovery: most sensitive tasks can run on-device, while a minority (long-thread synthesis, complex multi-tool planning) are where a larger remote model would add value, and those are exactly the tasks the privacy gate must govern.

### 11.2 The privacy gate: what is technically true

**There is no OS-level proof of data locality. [BLOCKED].** iOS sandboxes every app but grants network access by default. Unlike macOS, iOS has no opt-out networking entitlement an app can self-impose to provably forbid its own connections. "On-device only" is therefore an architectural promise we make and must substantiate, not something iOS attests.

What iOS gives us is defense in depth, not proof of non-exfiltration: the App Sandbox (isolation from other apps' data), Data Protection classes (hardware file encryption tied to lock state), and the Keychain plus Secure Enclave (hardware-isolated key storage, the right home for the OAuth tokens that email integration forces on us). The credible ways to *substantiate* an on-device claim: be open source and reproducible, ship a privacy manifest declaring no data collection, make the on-device-only mode literally not initialize any networking path for sensitive data, and be auditable. None of these is a cryptographic OS guarantee.

### 11.3 The three tiers the gate should distinguish

The product instinct to hard-gate cloud processing is sound, and the honest framing is three tiers, not two:

| Tier | Where data goes | Trust basis | Verifiable | Gate |
|---|---|---|---|---|
| **On-device model** (Apple Foundation Models, or our MLX/llama.cpp/MLC model) | Never leaves the device | Architectural, can be made auditable | Not OS-attested, but inspectable | **Default. No gate.** Marketable as "data never leaves your iPhone." |
| **Apple Private Cloud Compute** | Apple-silicon servers, deleted after response | Cryptographic attestation, stateless, non-targetable, publicly logged, Apple-blind | Yes (device refuses unlogged servers; transparency log) | Distinct gate, strongest remote option. Note: not reachable from the third-party Foundation Models API today, so likely not in play unless we use a system feature that uses it. |
| **Generic third-party cloud API** (our server, or an LLM vendor) | Vendor servers | Contract and vendor policy only | No technical attestation | **Hardest gate.** This is the tier the product's hard gate must protect against. |

The real trust difference: on-device is the only tier where exfiltration is *architecturally* prevented (subject to our honesty). Private Cloud Compute is the only *remote* tier with cryptographic, publicly verifiable, Apple-blind guarantees, so it is far more trustworthy than a generic cloud API, but it still means data leaves the device and should be gated separately from fully local processing. A generic cloud API rests entirely on contract and policy with no technical attestation.

### 11.4 The hard gate is now an App Store requirement

App Review Guideline 5.1.2(i), updated November 13, 2025, requires clear disclosure and *explicit permission before* personal data is shared with any third party, **including third-party AI**. Reviewers now expect in-app, visible consent (an actual interaction, not just a privacy-policy link) and granular per-data-type opt-in rather than a single onboarding master switch. The HIG and this rule converge on a consistent playbook for the kind of gate the product wants: default to on-device; trigger the gate just-in-time at the moment a capability needs the remote tier; show an explainer stating exactly which data leaves, to which provider, whether stored, retention, and whether used for training; use per-data-type toggles (separate health, email, messages, calendar); require an affirmative double confirmation for the hard gate; keep the current mode visibly displayed with one-tap revert; and never paywall consent. Apple Health's "all Health data stays on device" default and Proton's "even we cannot read it" framing are the reference points for messaging the trust boundary.

The useful conclusion for discovery: the product's instinct to hard-gate cloud processing is not only feasible, it aligns with what Apple now mandates, and the mechanisms to build it (just-in-time consent, per-type toggles, privacy manifest, Keychain-held tokens) all exist. What does not exist is any way to make the gate OS-enforced rather than developer-enforced.

---

## 12. What is genuinely hard or impossible

A consolidated list of the walls, so expectations are set:

- **Reading Apple Mail:** impossible. Email reading requires per-provider OAuth, which makes us the data custodian and may trigger Google's paid CASA assessment at scale.
- **Reading iMessage, SMS, or any third-party chat:** impossible. The assistant can only help compose a message for the user to send.
- **Reading the user's Discord messages or DMs, or acting as the user on Discord:** impossible in a Terms-compliant way. Discord prohibits user-account automation (self-bots) as a bannable offense, and its API is bot-only. The only compliant Discord capability is a server-backed bot the user explicitly invites into chosen channels, which never sees the user's DMs and always posts as the bot, not the user. See [Addendum A3](#a3-discord).
- **Reading the user's Slack at scale with no backend:** not viable. Slack's 2025 rate-limit change throttles non-Marketplace apps to roughly one `conversations.history` request per minute returning 15 messages, real-time reading needs a public server endpoint, and many workspaces require admin approval to install any app. See [Addendum A2](#a2-slack).
- **Reading other apps' notifications:** impossible. No notification-listener equivalent exists.
- **Writing medications or logging doses into Apple Health:** impossible. Health is read-only for medications; we own scheduling.
- **Having Apple Intelligence or the new Siri autonomously operate our calendar/tasks:** not available. No assistant schema for those domains, and the personal-context Siri is delayed.
- **Proving to the user, at the OS level, that data never leaves the device:** impossible. It is an architectural promise we make and substantiate.
- **Bypassing the silent switch for reminders without Apple's blessing:** requires the Critical Alerts entitlement, individually approved.
- **Becoming the system assistant or replacing Siri:** impossible.

---

## 13. What is clearly achievable on-device

The other side of the ledger, the surfaces where an on-device assistant can do real work today:

- **Calendar:** full read/write, plus a no-permission confirmation editor.
- **Tasks:** full read/write of the system Reminders store.
- **Medications and health:** read the user's real medication list, schedule, and adherence (iOS 26), plus the broader HealthKit data types, all on-device.
- **Reminders and attention:** local notifications up to Time-Sensitive (self-serve), rich interactive notifications, Live Activities and the Dynamic Island, custom sounds, and hands-free spoken announcements. Critical Alerts available if justified to Apple.
- **Ecosystem reach:** expose assistant actions to Siri, Shortcuts, Spotlight, the Action Button, and widgets via App Intents (already in the app), and index assistant content into Spotlight.
- **On-device reasoning:** Apple Foundation Models (free, never leaves device, tool-calling, constrained output) on capable devices, with our MLX-Swift small model as the universal fallback and for longer context.
- **Composition handoffs:** draft an email or message and hand it to the system compose sheet for the user to send.

The shape this suggests, without architecting: an on-device assistant whose strongest capabilities cluster around calendar, tasks, medications/health, and notifications, which uses on-device models by default, which reaches email and messaging only through compose handoffs (plus optional, separately gated provider integration for email reading), and which gates any cloud processing of sensitive data behind explicit per-type consent.

---

## 14. Open questions to verify before relying on them

These came up across the research as genuinely uncertain in mid-2026 and should be confirmed against live sources or in-Xcode before any are treated as load-bearing:

1. **Exact iOS availability badge for the Medications API** (`HKUserAnnotatedMedication`, `HKMedicationDoseEvent`). Confirmed as the iOS 26 cycle; verify the precise `@available` annotation in the Xcode SDK headers.
2. **Google CASA obligations for a no-backend, on-device-only Gmail client.** This is the single most important roadmap question and it is genuinely contested in 2026. A "local client" exemption exists in Google's User Data Policy, but the live policy framing has drifted toward user-count and server-capability triggers, and at least one current source states local-only does not waive CASA for Gmail's restricted scopes. Do not self-assert the exemption; get a written determination from Google during verification, and budget for CASA Tier 2 (a few hundred to ~$2k per year plus annual renewal) as the baseline. See [Addendum A1](#a1-gmail-as-the-email-source).
3. **Whether any iOS 26 point release added a write/log path for medication dose events.** Currently none is accessible.
4. **The Foundation Models context window on releases past 26.4.** It is 4,096 tokens today; Apple has signaled active management, so confirm if targeting a later point release.
5. **`increased-memory-limit` entitlement approval** for our app profile, if we ever push the local model past ~1.7B.
6. **Ship date and developer availability of the personal-context Siri** that would run third-party App Intents. Apple says "2026"; no third-party in-app-action execution was confirmed live as of 2026-06-04.
7. **Core Spotlight semantic-search quality on shipping iOS 26 devices**, which beta reports suggest is still maturing.
8. **Current App Review Guideline text (4.8, 5.1.x, 5.1.2(i))** at submission time, since these have moved recently.
9. **Slack's exact 2026 rate limits for non-Marketplace apps**, and whether a consumer assistant reading user messages can realistically be accepted into the Slack Marketplace (which is the only path back to usable limits). Confirm the current `conversations.history` numbers and the Marketplace review stance on broad `*:history` user-token scopes.
10. **Discord's current Message Content privileged-intent threshold (75 vs 100 servers)** and the unofficial DM-scope names, neither of which changes the conclusion that the user's DMs are off-limits, but both of which should be confirmed if any Discord work is scoped.

---

## 15. Key sources

Primary Apple documentation and sessions that anchor the load-bearing claims:

- EventKit iOS 17 permission changes: Apple TN3153, and WWDC23 "Discover Calendar and EventKit."
- HealthKit Medications API: WWDC25 session 321 "Meet the HealthKit Medications API," `HKUserAnnotatedMedication`, `HKMedicationDoseEvent`.
- Notifications: `UNNotificationInterruptionLevel`, the Critical Alerts entitlement and its request form, ActivityKit "Displaying live data," and Apple Support "Announce Notifications."
- App Intents and ecosystem: App Intents and App Intent Domains documentation, "Integrating actions with Siri and Apple Intelligence," WWDC25 session 275, and "Deprecated SiriKit Intent Domains."
- On-device LLM: Apple Newsroom and Apple ML Research on the Foundation Models framework, WWDC25 session 301, and TN3193 on the context window.
- Private Cloud Compute: Apple Security blog and the PCC Security Guide.
- Privacy and review: the App Review Guidelines (notably 5.1.2(i), 5.1.3), Apple's privacy-manifest documentation, and the HIG Privacy guidance.
- Email and messaging walls: MessageUI (`MFMailComposeViewController`, `MFMessageComposeViewController`), MailKit (macOS-only), the Messages framework, and SiriKit messaging intents.

Full URLs for each are preserved in the underlying research notes for this document and can be expanded into a formal bibliography if this moves past discovery.

---

# Addendum A (2026-06-06): Service deep dives, Gmail, Slack, Discord

This addendum extends the discovery with a focused look at three specific services the product wants the assistant to integrate with: Gmail as the email source, plus Slack and Discord for messaging. It uses the same classification legend as the main document, and for every capability it also states whether the work can be done **device-direct with no backend server** or whether it **requires a server**.

### Shared themes before the details

Three patterns repeat across all three services, and they matter more than any single API detail:

1. **All three are generic third-party cloud APIs.** Reaching any of them sends the user's data to Google, Slack, or Discord servers, and our processing of what comes back is exactly the "generic cloud" tier from Section 11.3. So even the parts that work are in the hardest privacy-gate tier, not the on-device default.
2. **Reading the user's messages is the hard part everywhere. Sending is comparatively easy.** Each service makes "compose and send on the user's behalf" relatively tractable, and "read the user's existing messages" either heavily gated (Gmail, Slack) or outright prohibited (Discord).
3. **Real-time delivery universally requires a server.** Push and event streams (Gmail Pub/Sub, the Slack Events API, the Discord Gateway) all need a backend with a public endpoint or a persistent socket. The only no-backend option is polling, and polling is sometimes throttled to the point of uselessness (Slack) or simply not viable for the target data (Discord).

The net effect: of the three, **only Gmail is a real candidate for a privacy-first, on-device integration**, and even that carries a contested compliance cost. Slack is reduced to "send only" without a backend, and Discord cannot do the requested job at all within its Terms.

---

## A1. Gmail as the email source

**Headline: Gmail read access is technically clean and fully device-direct over REST, but every meaningful read capability needs a Google *restricted scope*, which triggers OAuth verification plus a CASA security assessment. Whether a no-backend on-device client is exempt from CASA is the single most important and genuinely contested question, so plan for the cost and confirm with Google. Send-only avoids CASA entirely.**

### Capability to scope mapping

Every operation below is device-direct over HTTPS to `gmail.googleapis.com`. None requires a backend at the API level. The gating is OAuth scope and verification, not infrastructure.

| Capability | Method | Minimal scope | Scope class | Verdict |
|---|---|---|---|---|
| Read message body (full/raw) | `users.messages.get` | `gmail.readonly` | RESTRICTED | [CONSTRAINED] |
| Read metadata only (headers/labels, no body) | `users.messages.get` (metadata) | `gmail.metadata` | RESTRICTED | [CONSTRAINED] |
| List / search (`q` syntax) | `users.messages.list` | `gmail.readonly` | RESTRICTED | [CONSTRAINED] |
| Read/create/modify labels | `users.labels.*` | `gmail.labels` | NON-SENSITIVE | [SUPPORTED] |
| Modify (archive, trash, mark read, relabel) | `users.messages.modify` | `gmail.modify` | RESTRICTED | [CONSTRAINED] |
| Send | `users.messages.send` | `gmail.send` | SENSITIVE | [CONSTRAINED], no CASA |
| Drafts | `users.drafts.*` | `gmail.compose` or `gmail.modify` | RESTRICTED | [CONSTRAINED] |
| Incremental sync | `users.history.list` | `gmail.readonly` / `gmail.metadata` | RESTRICTED | [CONSTRAINED] |
| Real-time push of new mail | `users.watch` + Pub/Sub | (read scope) plus a webhook | RESTRICTED + infra | [CONSTRAINED], **needs server** |

Two traps worth flagging. First, **`gmail.metadata` is still a restricted scope even though it cannot read bodies**, so restricting to metadata does not buy you out of CASA. Second, the minimal single scope that covers full triage (read, label, archive, trash, mark read, draft, send, no permanent delete) is **`gmail.modify`**, one restricted scope rather than several.

### The classification tiers and the one architectural lever

Google classifies scopes as NON-SENSITIVE, SENSITIVE, or RESTRICTED. Sensitive scopes require OAuth app verification. Restricted scopes require verification **plus** a CASA security assessment. The lever this creates: **`gmail.send` is only sensitive, not restricted**, so a send-only or draft-only feature needs verification but **no CASA**. A read and triage feature is inherently a restricted-scope, CASA-bearing product. A phased v1 that only sends or drafts stays CASA-free.

### OAuth on iOS, concretely

Use the GoogleSignIn-iOS SDK (built on AppAuth, which uses `ASWebAuthenticationSession`). An embedded `WKWebView` is rejected by Google with `disallowed_useragent`, so the system browser flow is mandatory. Installed apps are public clients: a static client ID, no client secret, and PKCE. The full token exchange is **device-direct with no backend**, refresh tokens are returned for installed apps requesting offline access, and tokens belong in the iOS Keychain.

Two refresh-token traps to expect during development: while the OAuth app is in "Testing" publishing status, refresh tokens for test users **expire after 7 days**, forcing weekly re-auth until the app is verified and "In Production," and there is a per-user live-refresh-token cap. Plan one durable token per device.

### CASA, and the on-device exemption question

CASA (Cloud Application Security Assessment), run under the App Defense Alliance and mapped to OWASP ASVS, is triggered when a production app requests restricted scopes beyond the 100-user testing cap. Tiers: Tier 1 self-scan, Tier 2 authorized-lab DAST plus review (where most restricted-scope apps land), Tier 3 full manual audit. Google does not charge, the empanelled lab does: reported figures are roughly **$540 to $1,800 for Tier 2** and around **$4,500 for Tier 3**, renewed annually.

The crux for this product: Google's API Services User Data Policy has historically carried a **local-client exemption**, stating that "local client applications that only allow user-configured transmissions of Restricted Scope data from the device may be exempt." A privacy-first iOS app that fetches Gmail device-direct and processes entirely on-device is the strongest possible candidate for it. But the exemption is uncertain in 2026 for three reasons: it is discretionary ("may be exempt"), decided by a Google reviewer, not self-asserted; the live policy text now leans on user count and "ability to access data from or through a third-party server" rather than a clean local-client carve-out, and at least one current source states local-only does not waive CASA for Gmail; and the exemption evaporates the instant any email content is sent to a cloud LLM or our own backend, which would also trip Apple's Guideline 5.1.2(i).

| Architecture | Restricted scope? | CASA likely? | Confidence |
|---|---|---|---|
| Send-only (`gmail.send`) | No (sensitive) | No | High |
| Read/triage, 100% on-device, email never leaves device | Yes | Possibly exempt as local client, but discretionary and contested | Low, must verify with Google |
| Read/triage, email content sent to a cloud LLM | Yes | Yes, and not a "local client" | High |
| Read/triage routed through our own backend | Yes | Yes, definitively | High |

**Recommendation for discovery:** architect for the exemption (device-direct fetch, on-device inference, zero server touch of email content), because it is both the best shot at avoiding CASA and the correct privacy posture, but budget for CASA Tier 2 as the baseline and get a written determination from Google during verification rather than self-certifying. The safest zero-CASA launch is a send/draft-only v1.

### Push vs polling, and IMAP

Real-time push (`users.watch`) delivers to a Cloud Pub/Sub topic that pushes to an HTTPS webhook, so it **requires a backend**. The no-backend alternative is **polling the History API** (`users.history.list` from a stored `historyId`), which is fully device-direct, cheap on quota, and limited only by your poll cadence and iOS background-execution limits. This is the right design for a no-backend assistant.

IMAP is not an escape hatch. In 2026 Gmail IMAP/SMTP require OAuth XOAUTH2 with the **full `mail.google.com/` restricted scope** (the broadest of all), so IMAP triggers the same verification and CASA as the REST API while giving a coarser scope and worse sync ergonomics. App passwords still exist but require the user to enable 2FA and paste a generated password, a poor consumer flow Google keeps narrowing. **Use the REST API, not IMAP.**

### App Store and privacy

Offering Google sign-in as the primary login triggers Guideline 4.8, so plan to also offer Sign in with Apple or another privacy-respecting option for app account setup. The decisive privacy point: if email is fetched device-direct, processed on-device, and nothing is sent off-device, then under Apple's definition the email content is **not "collected,"** we can honestly declare "Data Not Collected," and Guideline 5.1.2(i) third-party-AI consent does not apply to that flow. The moment email content goes to a cloud LLM or our backend, both the CASA local-client exemption and the "not collected" declaration are lost and 5.1.2(i) consent becomes mandatory. Keeping Gmail processing on-device is what simultaneously protects the compliance posture, the privacy label, and the trust story.

---

## A2. Slack

**Headline: a no-backend, privacy-first iOS app can send messages as the user, but it cannot meaningfully read the user's Slack at scale. A 2025 rate-limit change throttles non-Marketplace apps to roughly one history request per minute, real-time reading needs a server, and many workspaces gate app installation behind admin approval.**

### Auth model

Slack apps are workspace-scoped. A user in N workspaces requires N separate authorizations. There are two token types: a **bot token** (`xoxb`) acting as a bot identity, and a **user token** (`xoxp`) acting as the user with the user's own visibility. For a personal assistant that reads and acts as the user, the **user token is mandatory**, because only it inherits the user's access to their DMs and private channels and can post as the user.

### Reading the user's messages: [BLOCKED] in practice without a backend

With a user token and the right scopes (`im:history` for DMs, `groups:history` for private channels, `channels:history` for public, `mpim:history` for group DMs, `search:read` for search), the API surface to read the user's messages **exists** and `conversations.history` / `conversations.replies` return the content. Device-direct in principle.

The wall is the **2025 rate-limit change**. Since mid-2025, and now fully in effect for essentially all existing installs, Slack throttles **non-Marketplace apps** on `conversations.history` and `conversations.replies` to approximately **one request per minute returning about 15 messages**, down from the old tier of dozens of requests per minute returning up to a thousand objects. A polling assistant cannot meaningfully keep up with a user's Slack at that rate. This effectively makes no-backend reading non-viable. [VERIFY the exact current numbers, but the direction and severity are confirmed across Slack's changelog, FAQ, and developer reports.]

### Real-time and the server question

The **Events API requires a public HTTPS endpoint** (a server) to receive event callbacks. **Socket Mode** uses an outbound WebSocket and so needs no public URL, but Socket Mode apps **cannot be distributed on the public Slack Marketplace**, which limits them to internal or single-workspace use. The legacy RTM API is deprecated for modern scoped apps. So real-time reading requires a server, and the no-backend path is limited to polling, which is exactly what the rate limit strangles.

### Marketplace listing

Normal (higher) rate limits are reserved for apps listed in the **Slack Marketplace**. Listing requires passing Slack's review, which tests endpoints for TLS and request signing (implying a backend), scrutinizes broad `*:history` user-token scopes and expects a narrow justified use case, and prohibits training LLMs on Slack data. A consumer assistant that reads a user's full Slack history is a hard sell for Marketplace approval.

### Sending: [SUPPORTED], device-direct

`chat.postMessage` with a user token posts as the user, is device-direct, and is not subject to the punishing history rate limits. This is the one clean Slack capability for a no-backend app.

### The admin gate

Many Slack workspaces, especially corporate ones, require **admin approval** to install any third-party app, or restrict installation entirely. A consumer assistant cannot assume it can be installed into an arbitrary user's workspace.

### Bottom line

A no-backend, privacy-first iOS assistant can **send as the user** but cannot **read the user's Slack at any useful scale**. The three compounding walls are the 2025 non-Marketplace rate limit, the server requirement for real-time, and per-workspace admin approval. Meaningful reading would require building a backend and getting into the Slack Marketplace, which contradicts both the on-device and the privacy-strict pillars and faces a skeptical review for this use case.

---

## A3. Discord

**Headline: a consumer, on-device, privacy-first assistant cannot read the user's Discord messages or DMs, and cannot send as the user, in a Terms-compliant way. Discord's API is bot-only, and automating a user account (a "self-bot") is a bannable Terms violation. The only compliant capability is a server-backed bot the user explicitly invites into chosen channels, which never sees the user's DMs and always posts as the bot.**

### The central wall: self-bots are prohibited

Reading a user's full message history and DMs, or sending as the user, technically requires driving the client API with the user's own account token. Discord explicitly prohibits this: "Automating normal user accounts (generally called 'self-bots') outside of the OAuth2/bot API is forbidden, and can result in an account termination." The Developer Policy separately bars obtaining user login credentials or tokens. There is no compliant variant, regardless of how benign, local, or user-consented the automation is. **[BLOCKED], applies whether device-direct or server-backed.**

### The bot-only model and what it cannot see

Discord's API is designed around **bot accounts**, a separate automation identity. A bot can only see messages where it is a member of the server **and** has channel read permission, and to receive message text it needs the **Message Content privileged intent**. A bot fundamentally **cannot** read servers it is not in, channels it lacks permission for, or **the user's DMs with other people** (a bot only sees DMs between the bot itself and a user). So even at its best, a bot is not the user and cannot reach the user's real conversations.

### The OAuth scopes that sound useful but are not

The `messages.read` scope is **not** a general "read the user's messages over REST" grant. It is tied to the **local RPC server** (the desktop overlay path on `127.0.0.1`), is whitelist-gated, and is desktop-only, so it is unavailable to a third-party iOS app. The scopes that would actually read a user's DMs (`dm_channels.read`, `dm_channels.messages.read`) are marked non-public and reserved for Discord's own first-party client. Third-party apps cannot request them. **[BLOCKED].**

### DMs and sending

Reading the user's DMs with other people is impossible by any compliant route (self-bot is banned, bots cannot see them, the relevant scopes are first-party-only). Sending **as the user** is likewise impossible, there is no scope or API for it. What sending **is** possible: a bot posting to channels it is in, webhooks posting to a server channel under a custom name (still a webhook identity, not the user, and not to DMs), and a user-installed app replying to its own interactions. None of these is "the assistant sends a message as me."

### Server requirement

Real-time message reception requires a **persistent Gateway WebSocket**, which a backgrounded iOS app cannot hold, so it needs an always-on backend. The HTTP Interactions endpoint alternative also needs a public HTTPS server and is only reactive to interactions the user explicitly triggers. An on-device-only, no-backend Discord assistant cannot do real-time reading. **[BLOCKED] by architecture.**

### Verification and privacy

Past roughly 100 servers a bot must be verified and approved for the Message Content intent, and Discord scrutinizes invasive use cases (ingesting message text into a third-party AI cloud is exactly the profile reviewers question). The Developer Policy also requires a clear privacy policy, limits data use to stated functionality, and restricts sharing with third parties, all of which cut against a "send the user's messages to our AI" design.

### Bottom line

For the stated goal ("read my Discord and reply as me"), the honest conclusion is **not possible within Discord's Terms**. The only compliant slice is a clearly disclosed, **server-backed, user-invited bot** scoped to specific channels the user opts into, which never touches the user's DMs, always posts as the bot, requires a backend, and is not privacy-pure (message text leaves to our server and to any AI provider). That contradicts both the on-device and the privacy-strict pillars. A trivial no-backend slice exists (outbound webhook posts, and reading the user's profile and server list via `identify` / `guilds`), but it reads no conversations and does not act as the user.

---

## A4. Cross-service comparison and synthesis

| Question | Gmail | Slack | Discord |
|---|---|---|---|
| Read the user's messages? | Yes, but restricted scope plus likely CASA | Yes via API, but 2025 rate limit makes no-backend reading non-viable | No, ToS-prohibited for the user's own messages/DMs |
| Send as the user? | Yes (`gmail.send`, sensitive, no CASA) | Yes (`chat.postMessage`, user token) | No, impossible by design |
| No-backend, device-direct possible? | Yes for fetch (poll History API) and send | Send yes, meaningful read no | No for any real-time reading |
| Real-time push without a server? | No (Pub/Sub needs a webhook) | No (Events API needs a server) | No (Gateway needs a persistent socket) |
| Biggest wall | CASA cost plus the contested on-device exemption | 2025 non-Marketplace rate limit | Self-bot prohibition plus bot-only model |
| Admin/account gate | Per-account OAuth, user-consented | Per-workspace, often admin-approved | Per-server bot invite, not the user |
| Privacy-gate tier | Generic cloud, but can stay on-device after fetch | Generic cloud | Generic cloud, server required |

The synthesis for discovery:

1. **Gmail is the only one of the three that fits the product's on-device, privacy-first thesis.** Fetch device-direct, process on-device, never send content off-device, and the privacy story holds. The open risk is purely the CASA exemption, which is a compliance and cost question, not a technical blocker. A send/draft-only phase avoids CASA entirely while the read path's exemption is confirmed with Google.
2. **Slack collapses to "send only" for a no-backend app.** Reading is gated by a rate limit that is hostile to polling, and fixing that means a backend plus Marketplace approval, which breaks the privacy posture and is unlikely to be granted for a broad-history consumer assistant. A useful "tell Slack X" send capability is achievable today, device-direct.
3. **Discord cannot do the requested job at all.** The self-bot prohibition and the bot-only model mean there is no compliant path to read the user's Discord or act as the user. The only compliant integration is a separate product shape (a user-invited server bot) that is neither on-device nor what was asked for. Recommend treating Discord as out of scope for a personal assistant unless the goal is reframed.

A useful framing for prioritization: these integrations form a clear gradient. Gmail is a real on-device candidate with a known compliance cost, Slack is a send-only convenience, and Discord is effectively closed. This mirrors the main document's finding for Apple's own apps, where reading is the universally hard capability and composing is the universally available one.

---

## A5. Addendum sources

Primary sources anchoring the addendum claims (full URLs are preserved in the research notes):

- **Gmail:** Google "Choose Gmail API scopes," the `users.messages` and `users.watch` REST references, the Gmail API quota page, "OAuth 2.0 for iOS and Desktop Apps," AppAuth-iOS, the restricted-scope and brand verification guides, the API Services User Data Policy (local-client exemption), the CASA security-assessment FAQ and annual recertification pages, and the "transition from less secure apps to OAuth" guidance.
- **Slack:** the Slack API scopes and OAuth v2 docs, `conversations.history` and `chat.postMessage` references, the 2025 rate-limit changelog and FAQ for non-Marketplace apps, the Events API and Socket Mode docs (including the Marketplace distribution restriction), and the Slack Marketplace review policy.
- **Discord:** the Discord Developer Portal OAuth2 and Gateway docs, the Interactions overview, the self-bot prohibition and Platform Manipulation policy, the Developer Policy and Developer Terms of Service, the Message Content privileged-intent review policy, and the user-installable-apps limitations.
- **Apple cross-cutting:** Guideline 4.8 (sign-in alternatives), Guideline 5.1.2(i) (third-party-AI consent), and Apple's "Collect" definition for the privacy nutrition label, all as cited in the main document.

Several items are flagged in-text as [VERIFY], most importantly the Gmail CASA on-device exemption (confirm directly with Google), Slack's exact current non-Marketplace rate-limit numbers, and Discord's current privileged-intent server threshold.
