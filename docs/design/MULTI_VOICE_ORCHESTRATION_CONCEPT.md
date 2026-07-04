# Multi-Voice Orchestration and Adaptive Learner Modeling for UnaMentis

## A design paper on bridging real-time voice interaction with frontier model depth

**Status:** Concept paper for implementation exploration
**Origin:** Voice-mode design session, July 2026

---

## 1. Summary

Current voice AI products force a choice between responsiveness and depth. Voice modes from major labs are typically separate, constrained systems rather than true voice interfaces to their frontier models, and the primary reason is latency: deep-thinking models cannot respond fast enough to sustain the rhythm of human conversation.

This paper proposes an architecture that dissolves that tradeoff through four interlocking ideas:

1. **The voice is the continuity layer, not the model.** A single controlled TTS pipeline lets multiple models of different capability serve one coherent conversational presence.
2. **Two presentation patterns, chosen per use case:** an invisible single narrator backed by multiple brains, or a transparent multi-voice "call in the expert" pattern.
3. **Latency amortization through staged dialogue.** Expensive frontier-model calls return rich payloads that a fast model unspools as improvised conversation over minutes, decoupling request rhythm from presentation rhythm.
4. **A dynamic, contextual learner profile** that tunes every layer of the system to the individual user, stored on device, inspectable, and continuously updated as a byproduct of conversation.

Together these form a system with continuity and capability spanning from sub-second acknowledgment to frontier-model reasoning, with the triad dialogue pattern (learner, bridge voice, expert voice) as a genuine differentiator for deep learning use cases.

---

## 2. The Problem

### 2.1 Voice modes are not voice interfaces

Historically, activating voice mode in a mainstream AI product has not meant speaking to the model in the current session. It has meant being handed to a different system: a different model, different guardrails, different constraints and capabilities. The voice experience may be built on recent technology, but it is not a voice interface to the frontier model the user was just working with.

UnaMentis already demonstrates the alternative: full STT and TTS wrapped around a given backend model, so the voice conversation is with that model, not a stand-in.

### 2.2 Latency breaks the illusion

The deeper reason labs ship separate voice systems is time. Human conversation tolerates pauses measured in hundreds of milliseconds. Frontier models thinking deeply take seconds to a minute or more. The moment a response takes noticeably long to begin, suspension of disbelief collapses and the interaction stops feeling like conversation.

Small fast models can hold conversational rhythm but lack depth. Frontier models have depth but cannot hold rhythm. Every current product picks one side of this tradeoff. The goal here is to stop picking.

---

## 3. Core Principle: The Voice Is the Continuity Layer

When you control the entire stack, including the TTS engine, the routing logic, and the context threading, the user's sense of talking to "one entity" does not depend on a single model producing every token. It depends on:

- **One consistent voice** in the audio sense: same TTS voice, same inflection profile, same prosody.
- **One consistent personality** in the linguistic sense: vocabulary, cadence, how it emotes, how it structures explanations. A voice persona is more than a sound; it is a full behavioral specification.

This has a practical consequence: raw output from multiple models should not be spoken directly. Different models write differently, and letting each speak in its own style destroys continuity even if the audio voice is identical. Instead, a single **narrating layer**, likely a fast model with a persona specification, renders all content in one consistent voice. Deeper models supply substance; the narrator supplies the speech.

Because UnaMentis controls TTS (Pocket TTS on device), routing, and context, this continuity is achievable in a way that stitched-together vendor APIs cannot match.

---

## 4. Two Presentation Patterns

### 4.1 Pattern A: Single narrator, many brains

One conversational presence, with an orchestrator invisibly routing behind it:

- **Tier 0: Canned responses.** A large, varied library of instant acknowledgments and engagement phrases ("Let me look into that," "I see what you're getting at, let's work through it") rendered in the persona voice. Zero latency. Variety matters so it never feels mechanical.
- **Tier 1: On-device model.** Capable enough for clarifications, follow-ups, and light reasoning, with near-real-time response. Requires recent-generation hardware but avoids the network entirely.
- **Tier 2: Fast hosted model** (Haiku class). Quick reasoning, conversation management, narration duty.
- **Tier 3: Frontier model** (Opus or Fable class). Deep analysis, invoked when the query warrants it.

Routing is invisible and automatic, driven by query complexity and the learner profile (Section 7). The user just keeps talking. Handoffs are masked by the wedge structure: canned acknowledgment, then on-device or fast-model engagement that starts down the path, while the deep probe runs in parallel and its result arrives already in flight.

This pattern suits companion-style interaction, quick assistance, and any context where the machinery should be invisible.

### 4.2 Pattern B: Calling in the expert

The alternative is to make the mixture of experts audible and honest. The primary voice, the one the user knows, explicitly brings in a second voice when depth is needed, the way you would pull a colleague into a conversation. Each voice has genuine individuality: distinct audio voice, distinct persona, distinct role.

This is more honest about what is happening under the hood. It converts a routing event into a natural social event. And for learning use cases specifically, it enables something a single voice cannot do well, which leads to the triad.

The reference point is NotebookLM's audio deep dive: two persistent voices with distinct personalities in a set pattern. But that is non-interactive theater. What follows is a live, barge-in-capable version built for tutoring.

---

## 5. The Triad: Learner, Bridge, Expert

### 5.1 The structure

Three participants:

- **The learner** (the human user).
- **The bridge voice.** Fast model. Understands where the learner is, speaks the learner's language, advocates for the learner's comprehension.
- **The expert voice.** Frontier model. Provides depth without diluting it.

The bridge and expert hold a genuine dialogue with each other, and both engage the learner. The dynamic is triangular: expert and bridge discussing, bridge and learner Socratically probing, learner able to barge in on any of it.

### 5.2 Why this works pedagogically

Most people do not delve, prod, and tease information out of an expert system on their own. Even capable learners often circle a question they cannot quite verbalize. The bridge voice solves this by:

- **Asking the questions the learner is dancing around.** When the bridge verbalizes the half-formed question, comprehension often falls into place immediately. Critically, a third party asking removes the ego cost of admitting you do not know how to phrase something.
- **Translating between registers.** The bridge speaks to the learner on the learner's terms and to the expert on the expert's terms, keeping the expert's content pitched at the learner's true conceptual level without forcing the learner to operate in unfamiliar vocabulary.
- **Modeling how to think.** Watching two voices genuinely build on and challenge each other teaches reasoning process, not just conclusions. Answers you cannot engage with do not build comprehension; a visible dialogue gives the learner handles to grab.

Single-voice Socratic tutoring often feels like interrogation. The triad distributes that pressure. It maximizes what a session can accomplish without losing engagement, and it scales in principle to more voices, though the triad appears to be the sweet spot.

### 5.3 Persona contracts

Each voice needs a formal specification, effectively a persona contract: audio voice, vocabulary range, cadence, emotional register, role boundaries, and awareness of the other voices and their roles. Voices must be designed to collaborate, not merely coexist. Throwing multiple models at a question without role definitions produces voices talking past each other.

---

## 6. Latency Amortization: Staged Dialogue and the Cognition Buffer

This is the architectural move that makes the triad viable despite frontier-model latency.

### 6.1 Decouple request rhythm from presentation rhythm

Naive design: each conversational turn triggers a model call, and the user waits for each response. Frontier latency makes this unusable.

Proposed design: a single contextual, system-prompt-wrapped request to the frontier model returns a **rich structured payload**, not one answer. The payload contains key points, derivations, anticipated learner questions, counterpoints, analogies, and supporting material. The dialogue between bridge and expert voices then becomes the **delivery mechanism** that unspools this payload over minutes of staged but flexible conversation.

A one-time thirty-second fetch is invisible when it purchases five minutes of dialogue. While the current payload plays out, the orchestrator asynchronously prefetches the next one, so by the time material runs low, fresh depth has already arrived. The latency is amortized across the performance instead of sitting in front of it.

### 6.2 The buffer is material, not a script

This is the same principle as a streaming video playback buffer, applied to cognition. The distinction that keeps it from feeling canned: the fast model does not read the payload linearly. It improvises against it. It reorders chunks based on where the learner's attention actually goes, expands what lands, and skips what does not.

Barge-in therefore does not break the system:

- If the learner's interruption is answerable from buffered content, the bridge handles it instantly.
- If it genuinely exceeds the buffer, that is the natural dramatic beat for "good question, let me put that to him," and a real fetch happens behind a legitimate conversational moment. The wedge structure (canned phrase, then fast-model engagement, then deep result) fills the gap.

### 6.3 Integrity constraint: the bridge never fabricates

One hard rule must be designed in from the start: **the bridge voice must never invent the expert's position while waiting for it.** The bridge performs from what the expert actually said (the payload) or explicitly defers. A bridge that guesses and later gets contradicted by the real expert response would quietly destroy trust in the entire pattern. Vamping is legitimate; ventriloquism is not.

### 6.4 Staleness detection

The staged approach introduces one genuinely subtle engineering problem: knowing when the learner has veered far enough that the buffered payload no longer covers the ground being walked. The orchestrator needs a staleness signal that triggers cache invalidation and a fresh fetch, rather than allowing the bridge to stretch old material over new territory. Getting this detection right is likely where the hardest engineering lives, and it deserves early prototyping attention.

---

## 7. The Dynamic Learner Profile

### 7.1 Contextual, not scalar

Every learner presents a complex context. A statement like "12th grade vocabulary" is almost always an oversimplification. Real capability is contextual and relative: vocabulary can be off the charts in one domain and rudimentary in another, and the same is true of conceptual depth, abstraction tolerance, and preferred representation.

The profile is therefore best modeled as a **sparse matrix**: dimensions such as vocabulary, conceptual depth, representation preference (analogies and examples versus raw facts and first-principles structure), and engagement style, each indexed per domain and where warranted per subdomain. Never averaged into one number.

Two independently varying dimensions deserve explicit separation:

- **Vocabulary versus comprehension.** A self-taught learner may have deep conceptual understanding with nonstandard terminology; fluent jargon can mask shallow understanding. Tracking these separately lets the bridge adopt the learner's actual vocabulary while the expert's content stays pitched at true conceptual level. Conflating them produces the classic tutoring failure of talking down to someone conceptually because their terminology flagged them as a beginner.
- **Representation preference is itself contextual.** The same person may need analogies heavily in one domain and find them patronizing in a domain they intuitively grasp, where they want the meat of the matter directly.

### 7.2 Bootstrapping and continuous assessment

- **Bootstrap:** a deliberate but non-overwhelming initialization. Short interview-style exchanges distributed across roughly the first week of use, never as one large intake session.
- **Continuous update:** after bootstrap, the profile evolves as a byproduct of ordinary conversation. Every barge-in, every "wait, what does that mean," every question the learner asks and every question they do not need to ask is a labeled observation. The bridge voice is effectively running continuous assessment disguised as dialogue, which is far richer signal than any quiz, and it costs the learner nothing.
- **Never complete by design:** the profile models a moving target. Learning changes the learner. The profile is a perpetual work in progress and should be architected as such.

### 7.3 Hypotheses, not verdicts

Profile entries should carry confidence levels and be treated as hypotheses. People have off days; a system that quietly concludes a learner is weak in an area and permanently simplifies becomes a ceiling instead of a scaffold. Two mitigations:

- **Deliberate probes:** occasionally pitch content slightly above the modeled level to test whether the model is stale in either direction.
- **Decay and re-testing:** confidence in old observations should decay, prompting fresh evidence gathering.

### 7.4 Privacy and inspectability

The profile lives on device. This is the right privacy posture, and it also solves a product problem: people will tolerate and even value a rich cognitive profile **that they can inspect and correct**. A user-visible, user-editable profile keeps the bootstrap interviews from feeling like surveillance and turns the profile into a shared artifact between learner and system rather than a hidden dossier. Inspectability is both the ethical move and the trust-building one.

### 7.5 The profile drives the whole stack

The profile is not a bolt-on personalization feature. It feeds every layer described above:

- **Routing:** what complexity of query goes to which tier for this learner in this domain.
- **Prefetch strategy:** the same buffer architecture fills differently per learner. For an analogy-driven learner, the frontier payload should arrive loaded with analogies to improvise from; for a first-principles learner, structured derivations. Same machinery, different fill.
- **Persona tuning:** the bridge voice's vocabulary and register per domain.
- **Socratic calibration:** which questions the bridge asks on the learner's behalf, and at what level.

---

## 8. Implementation Sketch for UnaMentis

### 8.1 Component map

| Component | Role | Notes |
|---|---|---|
| Orchestrator | Routing across tiers, prefetch scheduling, staleness detection, cache invalidation | The core new build; owns the session state machine |
| Persona contracts | Per-voice specification files: audio voice, vocabulary, cadence, role, awareness of other voices | Versioned documents; the narrating layer enforces them |
| Canned response library | Tier 0 instant engagement, rendered in persona voices, high variety | Pre-generated through the same TTS for perfect continuity |
| On-device model | Tier 1 fast local reasoning and narration fallback | Recent-generation iPhone/Android; pairs with existing Pocket TTS work |
| Payload schema | Structured format for frontier-model responses: key points, anticipated questions, counterpoints, analogies, derivations | The contract between expert model and bridge improvisation |
| Cognition buffer | Client-side store of active payloads with coverage metadata | Coverage metadata is what makes staleness detection possible |
| Learner profile store | On-device sparse contextual model with confidence weights, user-visible editor | Update pipeline consumes conversation events |
| Barge-in handling | Already a UnaMentis differentiator | Extended to route interruptions against the buffer first |

### 8.2 Existing assets

UnaMentis already holds most of the hard prerequisites: on-device TTS via the Pocket TTS port, full-duplex barge-in, iOS and Android clients, a management server, and evaluation infrastructure from edu-voice-ai-eval for measuring whether any of this actually improves learning outcomes. The missing pieces are the orchestrator, the payload schema, the buffer, and the profile store. None require new research; they require design discipline and iteration.

### 8.3 Suggested phasing

1. **Phase 1: Single narrator with wedge.** Canned library plus fast-model narration over frontier payloads, one voice. Proves latency amortization and payload improvisation with the least surface area.
2. **Phase 2: Payload schema and staleness detection.** Formalize the buffer, instrument coverage, prototype invalidation heuristics. This is the highest-risk engineering; front-load it.
3. **Phase 3: The triad.** Introduce the second voice with persona contracts and the no-fabrication rule enforced at the orchestrator level. Evaluate against Phase 1 with real learning tasks.
4. **Phase 4: Learner profile.** Bootstrap flow, continuous assessment pipeline, profile-driven prefetch, and the user-facing profile editor.

Each phase is independently shippable and independently testable against the eval framework.

---

## 9. Open Problems and Risks

- **Staleness detection quality.** Too aggressive and the system thrashes with refetches; too lax and the bridge stretches stale material. Needs empirical tuning and probably a hybrid of semantic-distance heuristics and explicit bridge-model judgment.
- **Improvisation quality of the narrating model.** The whole illusion rests on the fast model rendering payload content naturally rather than reciting it. Persona contracts and payload schema design directly determine this.
- **Dialogue rhythm asymmetry in the triad.** Even with buffering, the seam between bridge and expert can show if turn pacing is unnatural. Staged dialogue must include timing direction, not just content.
- **Profile miscalibration harms.** A wrong profile actively degrades the experience. Confidence weighting, probes, and user editability are mitigations, not solutions; monitor for ceiling effects.
- **Hardware floor for on-device tier.** Tier 1 restricts the full experience to recent devices; the architecture should degrade gracefully to Tiers 0, 2, and 3 on older hardware.
- **Evaluation.** "Feels seamless" and "teaches better" are different claims. The second is the one that matters for UnaMentis and needs learning-outcome measurement, not just latency and engagement metrics.

---

## 10. Closing

The through-line of this design is that the tradeoff between conversational responsiveness and frontier-model depth is an artifact of naive architecture, not a law. Owning the full stack, voice, routing, context, and profile, allows the seams between models to be either hidden behind one continuous persona or turned into an honest and pedagogically powerful multi-voice dialogue. The triad pattern in particular, a live, interactive, learner-advocating version of what NotebookLM only performs as theater, is a capability no current product offers and one UnaMentis is unusually well positioned to build.
